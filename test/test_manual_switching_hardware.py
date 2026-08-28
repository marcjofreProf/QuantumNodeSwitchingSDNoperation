#!/usr/bin/env python3
import sys
import os
import time

# --- Path Resolution ---
# Ensure Python can find the repository root directory
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.gnoi_driver import OpticalMatrixDriver
from driver.netconf_driver import NetconfHardwareDriver

def run_hardware_test():
    print("==================================================")
    print("   Quantum SDN: Universal Hardware Test Sequence   ")
    print("==================================================\n")

    # ----------------------------------------------------
    # STAGE 1: gNOI Hardware Driver (Optical Matrix / MEMS)
    # ----------------------------------------------------
    print(">>> [STAGE 1/2] Testing gNOI Hardware Driver (OpticalMatrixDriver)...")
    gnoi_driver = None
    try:
        gnoi_driver = OpticalMatrixDriver()
        
        print("  [gNOI 1A] Engaging MEMS Crossconnect (ON)...")
        gnoi_driver.trigger_crossconnect(True)
        time.sleep(2)
        
        print("  [gNOI 1B] Disengaging MEMS Crossconnect (OFF)...")
        gnoi_driver.trigger_crossconnect(False)
        print("  [SUCCESS] gNOI Hardware Driver stage completed.")

    except Exception as e:
        print(f"  [ERROR] gNOI Hardware Test failed: {e}")
    finally:
        if gnoi_driver:
            print("  Releasing gNOI GPIO resources...")
            try:
                gnoi_driver.release()
            except Exception:
                pass

    print("\n--------------------------------------------------\n")

    # ----------------------------------------------------
    # STAGE 2: NETCONF Hardware Driver (VOA / Switch)
    # ----------------------------------------------------
    print(">>> [STAGE 2/2] Testing NETCONF Hardware Driver (NetconfHardwareDriver)...")
    try:
        netconf_driver = NetconfHardwareDriver()
        
        print("  [NETCONF 2A] Enabling NETCONF Switch State (ON)...")
        netconf_driver.set_netconf_switch_state(True)
        time.sleep(2)
        
        print("  [NETCONF 2B] Disabling NETCONF Switch State (OFF)...")
        netconf_driver.set_netconf_switch_state(False)
        print("  [SUCCESS] NETCONF Hardware Driver stage completed.")

    except Exception as e:
        print(f"  [ERROR] NETCONF Hardware Test failed: {e}")

    print("\n==================================================")
    print("   Universal Hardware Test Sequence Complete      ")
    print("==================================================")

if __name__ == "__main__":
    run_hardware_test()
