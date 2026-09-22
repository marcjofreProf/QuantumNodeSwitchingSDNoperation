import sys
import os
import time
import logging
from concurrent import futures
import grpc

# PROJECT_DIR is the repo root (parent of agent/).
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Make proto/ a top-level import root. gnmi_pb2.py internally does
# "from github.com.openconfig... import gnmi_ext_pb2", which only resolves
# if proto/ itself is on sys.path (so that github/ is a top-level package
# and gnmi_ext_pb2 lives under github/com/openconfig/gnmi/proto/gnmi_ext/).
sys.path.insert(0, PROJECT_DIR)
sys.path.insert(0, os.path.join(PROJECT_DIR, "proto"))

# Standard ONF gNMI stubs (top-level, because proto/ is on sys.path).
import gnmi_pb2
import gnmi_pb2_grpc

# Custom gNOI switching stubs (also top-level from proto/).
import quantum_gnoi_switching_pb2
import quantum_gnoi_switching_pb2_grpc

# Driver lives in the repo root, importable via PROJECT_DIR.
from driver.gnoi_driver import OpticalMatrixDriver

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')


# ---------------------------------------------------------------------------
# Standard ONF gNMI service implementation
#
# This server speaks the standard gNMI 0.9.0 protocol as generated from
# openconfig/gnmi v0.9.1 gnmi.proto. It is wire-compatible with gnmic and
# with the standard gNMI client used by the terminal benchmark
# (tests/gnmi_daemon.py).
#
# The model plugin on onos-config expects the path
#     /switching/state
# with an enum value of "enabled" or "disabled". We expose that as a
# config leaf, and accept standard gNMI Set requests.
# ---------------------------------------------------------------------------
class QuantumGnmiServicer(gnmi_pb2_grpc.gNMIServicer):
    def __init__(self, driver):
        self.driver = driver
        self.current_state = "disabled"
        # Advertise our models and encodings. Using the standard enums so
        # gnmic and pygnmi display them correctly instead of raw ASCII codes.
        self.supported_models = [
            gnmi_pb2.ModelData(
                name="openconfig-interfaces",
                organization="OpenConfig working group",
                version="2017-07-14",
            ),
            gnmi_pb2.ModelData(
                name="controller-quantum-switching",
                organization="Quantum SDN Project",
                version="2026-08-29",
            ),
        ]
        self.supported_encodings = [
            gnmi_pb2.Encoding.JSON,
            gnmi_pb2.Encoding.JSON_IETF,
            gnmi_pb2.Encoding.PROTO,
        ]

    # -- Capabilities ------------------------------------------------------
    def Capabilities(self, request, context):
        logging.info("gNMI Capabilities request")
        return gnmi_pb2.CapabilityResponse(
            supported_models=self.supported_models,
            supported_encodings=self.supported_encodings,
            gNMI_version="0.9.0",
        )

    # -- Get ---------------------------------------------------------------
    def Get(self, request, context):
        logging.info(f"gNMI Get request: {request}")
        # Build a Path for /switching/state
        path = gnmi_pb2.Path(
            elem=[
                gnmi_pb2.PathElem(name="switching"),
                gnmi_pb2.PathElem(name="state"),
            ]
        )
        val = gnmi_pb2.TypedValue(string_val=self.current_state)
        update = gnmi_pb2.Update(path=path, val=val)
        notification = gnmi_pb2.Notification(update=[update])
        return gnmi_pb2.GetResponse(notification=[notification])

    # -- Set ---------------------------------------------------------------
    def Set(self, request, context):
        logging.info(f"gNMI Set request: {request}")

        # Extract the value from the first update in the request.
        target_state = None
        if request.update:
            val = request.update[0].val
            if val.HasField("string_val"):
                target_state = val.string_val.strip().lower()

        if target_state is None:
            # Fall back: assume any Set means "enabled"
            target_state = "enabled"

        if target_state not in ("enabled", "disabled"):
            logging.warning(f"Unknown target state: {target_state}, mapping to enabled")
            target_state = "enabled"

        hardware_state = (target_state == "enabled")
        success = self.driver.trigger_crossconnect(hardware_state)

        if success:
            self.current_state = target_state

        # Build a standard SetResponse echoing the update.
        update_result = gnmi_pb2.UpdateResult(
            op=gnmi_pb2.UpdateResult.UPDATE,
            path=gnmi_pb2.Path(
                elem=[
                    gnmi_pb2.PathElem(name="switching"),
                    gnmi_pb2.PathElem(name="state"),
                ]
            ),
        )
        return gnmi_pb2.SetResponse(
            response=[update_result],
            timestamp=int(time.time() * 1e9),
        )


# ---------------------------------------------------------------------------
# Custom gNOI switching service (unchanged from the original)
# ---------------------------------------------------------------------------
class QuantumGnoiSwitchingServicer(quantum_gnoi_switching_pb2_grpc.QuantumGnoiSwitchingServiceServicer):
    def __init__(self, driver):
        self.driver = driver
        self.current_state = False

    def SetCrossConnect(self, request, context):
        target_state = request.state
        logging.info(f"gNOI SetCrossConnect(state={target_state})")
        success = self.driver.trigger_crossconnect(target_state)
        if success:
            self.current_state = target_state
            msg = f"Successfully set crossconnect to {target_state}"
        else:
            msg = "Hardware error: Failed to trigger MEMS matrix."

        return quantum_gnoi_switching_pb2.CrossConnectResponse(
            success=success,
            message=msg,
        )

    def GetCrossConnectStatus(self, request, context):
        logging.info("gNOI GetCrossConnectStatus")
        return quantum_gnoi_switching_pb2.StatusResponse(
            is_connected=self.current_state,
            switch_type=self.driver.config.get("switch_type", "Unknown"),
        )


def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    driver = OpticalMatrixDriver()

    # Register the standard gNMI servicer
    gnmi_pb2_grpc.add_gNMIServicer_to_server(
        QuantumGnmiServicer(driver), server
    )
    # Register the custom gNOI switching servicer
    quantum_gnoi_switching_pb2_grpc.add_QuantumGnoiSwitchingServiceServicer_to_server(
        QuantumGnoiSwitchingServicer(driver), server
    )

    port = "50051"
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    logging.info(f"Unified standard gNMI + custom gNOI agent on port {port}")

    try:
        while True:
            time.sleep(86400)
    except KeyboardInterrupt:
        logging.info("Shutting down gRPC server...")
        server.stop(0)
        driver.release()


if __name__ == "__main__":
    serve()
