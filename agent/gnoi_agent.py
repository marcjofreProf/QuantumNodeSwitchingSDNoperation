import sys
import os
import time
import logging
from concurrent import futures
import grpc

# Path resolution for root modules
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.switch_control import OpticalMatrixDriver
# Updated to new protobuf filenames
from proto import quantum_gnoi_switching_pb2
from proto import quantum_gnoi_switching_pb2_grpc

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')[cite: 9]

# Updated inheritance to match the new gNOI protobuf service name
class QuantumGnoiSwitchingServicer(quantum_gnoi_switching_pb2_grpc.QuantumGnoiSwitchingServiceServicer):
    def __init__(self, driver):[cite: 9]
        self.driver = driver[cite: 9]
        self.current_state = False[cite: 9]

    def SetCrossConnect(self, request, context):[cite: 9]
        target_state = request.state[cite: 9]
        logging.info(f"gRPC command received: SetCrossConnect(state={target_state})")[cite: 9]
        
        success = self.driver.trigger_crossconnect(target_state)[cite: 9]
        if success:[cite: 9]
            self.current_state = target_state[cite: 9]
            msg = f"Successfully set crossconnect to {target_state}"[cite: 9]
        else:[cite: 9]
            msg = "Hardware error: Failed to trigger MEMS matrix."[cite: 9]

        # Updated response message call
        return quantum_gnoi_switching_pb2.CrossConnectResponse(
            success=success,[cite: 9]
            message=msg[cite: 9]
        )

    def GetCrossConnectStatus(self, request, context):[cite: 9]
        logging.info("gRPC command received: GetCrossConnectStatus")[cite: 9]
        # Updated response message call
        return quantum_gnoi_switching_pb2.StatusResponse(
            is_connected=self.current_state,[cite: 9]
            switch_type=self.driver.config.get("switch_type", "Unknown")[cite: 9]
        )

def serve():[cite: 9]
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))[cite: 9]
    driver = OpticalMatrixDriver()[cite: 9]
    
    # Updated servicer registration function to match new proto definitions
    quantum_gnoi_switching_pb2_grpc.add_QuantumGnoiSwitchingServiceServicer_to_server(
        QuantumGnoiSwitchingServicer(driver), server
    )
    
    port = "50051"[cite: 9]
    server.add_insecure_port(f"[::]:{port}")[cite: 9]
    server.start()[cite: 9]
    logging.info(f"gNOI Quantum Agent running and listening on port {port}...")[cite: 9]
    
    try:[cite: 9]
        while True:[cite: 9]
            time.sleep(86400)[cite: 9]
    except KeyboardInterrupt:[cite: 9]
        logging.info("Shutting down gRPC agent...")[cite: 9]
        server.stop(0)[cite: 9]
        driver.release()[cite: 9]

if __name__ == "__main__":[cite: 9]
    serve()[cite: 9]
