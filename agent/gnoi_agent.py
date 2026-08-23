import sys
import os
import time
import logging
from concurrent import futures
import grpc

# Path resolution for root modules
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.switch_control import OpticalMatrixDriver
import quantum_gnoi_switching_pb2
import quantum_gnoi_switching_pb2_grpc

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

class QuantumGnoiSwitchingServicer(quantum_gnoi_switching_pb2_grpc.QuantumGnoiSwitchingServiceServicer):
    def __init__(self, driver):
        self.driver = driver
        self.current_state = False

    def SetCrossConnect(self, request, context):
        target_state = request.state
        logging.info(f"gRPC command received: SetCrossConnect(state={target_state})")
        
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
        logging.info("gRPC command received: GetCrossConnectStatus")
        return quantum_gnoi_switching_pb2.StatusResponse(
            is_connected=self.current_state,
            switch_type=self.driver.config.get("switch_type", "Unknown")
        )

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    driver = OpticalMatrixDriver()
    
    quantum_gnoi_switching_pb2_grpc.add_QuantumGnoiSwitchingServiceServicer_to_server(
        QuantumGnoiSwitchingServicer(driver), server
    )
    
    port = "50051"
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    logging.info(f"gNOI Quantum Agent running and listening on port {port}...")
    
    try:
        while True:
            time.sleep(86400)
    except KeyboardInterrupt:
        logging.info("Shutting down gRPC agent...")
        server.stop(0)
        driver.release()

if __name__ == "__main__":
    serve()
