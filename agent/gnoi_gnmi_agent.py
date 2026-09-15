import sys
import os
import time
import logging
from concurrent import futures
import grpc

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.gnoi_driver import OpticalMatrixDriver
from proto import quantum_gnoi_switching_pb2
from proto import quantum_gnoi_switching_pb2_grpc
from proto import quantum_gnmi_switching_pb2
from proto import quantum_gnmi_switching_pb2_grpc

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

class QuantumGnmiServicer(quantum_gnmi_switching_pb2_grpc.gNMIServicer):
    def __init__(self, driver):
        self.driver = driver
        self.current_state = False

    def Capabilities(self, request, context):
        logging.info("gNMI Capabilities Request received")
        return quantum_gnmi_switching_pb2.CapabilityResponse(
            gNMI_version="0.7.0",
            supported_encodings=["JSON_IETF", "PROTO"]
        )

    def Get(self, request, context):
        logging.info("gNMI Get Request received")
        val = quantum_gnmi_switching_pb2.TypedValue(
            string_val="ENABLED" if self.current_state else "DISABLED"
        )
        update = quantum_gnmi_switching_pb2.Update(val=val)
        return quantum_gnmi_switching_pb2.GetResponse(notification=[update])

    def Set(self, request, context):
        logging.info(f"gNMI Set Request received: {request}")
        # Parse set request state change
        target_state = True
        if request.delete:
            target_state = False

        success = self.driver.trigger_crossconnect(target_state)
        if success:
            self.current_state = target_state

        res_val = quantum_gnmi_switching_pb2.TypedValue(
            string_val="SUCCESS" if success else "FAILED"
        )
        response_update = quantum_gnmi_switching_pb2.Update(val=res_val)
        return quantum_gnmi_switching_pb2.SetResponse(response=[response_update])


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
            message=msg
        )

    def GetCrossConnectStatus(self, request, context):
        logging.info("gNOI GetCrossConnectStatus")
        return quantum_gnoi_switching_pb2.StatusResponse(
            is_connected=self.current_state,
            switch_type=self.driver.config.get("switch_type", "Unknown")
        )

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    driver = OpticalMatrixDriver()
    
    # Register both gNMI and gNOI servicers on the same gRPC server
    quantum_gnmi_switching_pb2_grpc.add_gNMIServicer_to_server(
        QuantumGnmiServicer(driver), server
    )
    quantum_gnoi_switching_pb2_grpc.add_QuantumGnoiSwitchingServiceServicer_to_server(
        QuantumGnoiSwitchingServicer(driver), server
    )
    
    port = "50051"
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    logging.info(f"Unified gNMI/gNOI Agent running on port {port}...")
    
    try:
        while True:
            time.sleep(86400)
    except KeyboardInterrupt:
        logging.info("Shutting down gRPC server...")
        server.stop(0)
        driver.release()

if __name__ == "__main__":
    serve()
