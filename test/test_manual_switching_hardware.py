#!/usr/bin/env python3
import sys
import os
import time

# --- Path Resolution ---
# Ensure Python can find the 'driver' directory at the repository root
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.switch_control import OpticalMatrixDriver

def run_hardware_test():
    print("=== Quantum SDN: Manual Hardware Test ===")
    try:
        driver = OpticalMatrixDriver()
        
        print("\n[TEST 1] Engaging MEMS Crossconnect (ON)...")
        driver.trigger_crossconnect(True)
        time.sleep(3)
        
        print("\n[TEST 2] Disengaging MEMS Crossconnect (OFF)...")
        driver.trigger_crossconnect(False)
        
    except Exception as e:
        print(f"\n[ERROR] Test failed: {e}")
    finally:
        print("\nReleasing hardware resources...")
        try:
            driver.release()
        except:
            pass
        print("Test complete.")

if __name__ == "__main__":
    run_hardware_test()
