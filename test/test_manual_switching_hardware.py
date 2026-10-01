#!/usr/bin/env python3
import sys
import os
import time

# --- Path Resolution ---
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from driver.gnoi_driver import OpticalMatrixDriver
from driver.netconf_driver import NetconfHardwareDriver


def describe_pin(pin_spec):
    """Human-readable chip:line for logging."""
    if pin_spec is None:
        return "(not configured)"
    if isinstance(pin_spec, dict):
        return f"{pin_spec['chip']}:{pin_spec['line']}"
    return f"gpiochip{pin_spec // 32}:{pin_spec % 32} (raw {pin_spec})"


def run_hardware_test():
    print("==================================================")
    print("   Quantum SDN: Universal Hardware Test Sequence   ")
    print("==================================================\n")

    # --------------------------------------------------
    # STAGE 1: gNOI Hardware Driver
    # --------------------------------------------------
    print(">>> [STAGE 1/2] Testing gNOI Hardware Driver (OpticalMatrixDriver)...")
    gnoi_driver = None
    all_ok = True
    try:
        gnoi_driver = OpticalMatrixDriver()

        print("  Resolved pins:")
        print(f"    port_A_in   -> {describe_pin(gnoi_driver.port_a_pin)}")
        print(f"    port_B_out  -> {describe_pin(gnoi_driver.port_b_pin)}")
        print(f"    enable_pin  -> {describe_pin(gnoi_driver.enable_pin)}")
        print(f"    strobe_pin  -> {describe_pin(gnoi_driver.strobe_pin)}")

        print("  [gNOI 1A] Engaging MEMS Crossconnect (ON)...")
        ok_on = gnoi_driver.trigger_crossconnect(True)
        print(f"  [gNOI 1A] driver returned: {ok_on}")
        all_ok = all_ok and ok_on
        time.sleep(1)

        print("  [gNOI 1B] Disengaging MEMS Crossconnect (OFF)...")
        ok_off = gnoi_driver.trigger_crossconnect(False)
        print(f"  [gNOI 1B] driver returned: {ok_off}")
        all_ok = all_ok and ok_off
        time.sleep(2)

        if all_ok:
            print("  [SUCCESS] gNOI Hardware Driver stage completed.")
        else:
            print("  [FAIL] gNOI stage reported at least one hardware failure.")

    except Exception as e:
        print(f"  [ERROR] gNOI Hardware Test failed: {e}")
        all_ok = False
    finally:
        if gnoi_driver:
            print("  Releasing gNOI GPIO resources...")
            try:
                gnoi_driver.release()
            except Exception:
                pass

    print("\n--------------------------------------------------\n")

    # --------------------------------------------------
    # STAGE 2: NETCONF Hardware Driver
    # --------------------------------------------------
    print(">>> [STAGE 2/2] Testing NETCONF Hardware Driver (NetconfHardwareDriver)...")
    try:
        netconf_driver = NetconfHardwareDriver()

        print("  Resolved pins:")
        print(f"    port_a_pin  -> {describe_pin(netconf_driver.port_a_pin)}")
        print(f"    port_b_pin  -> {describe_pin(netconf_driver.port_b_pin)}")
        print(f"    strobe_pin  -> {describe_pin(netconf_driver.strobe_pin)}")

        print("  [NETCONF 2A] Enabling NETCONF Switch State (ON)...")
        ok_on = netconf_driver.set_netconf_switch_state(True)
        print(f"  [NETCONF 2A] driver returned: {ok_on}")
        all_ok = all_ok and ok_on
        time.sleep(1)

        print("  [NETCONF 2B] Disabling NETCONF Switch State (OFF)...")
        ok_off = netconf_driver.set_netconf_switch_state(False)
        print(f"  [NETCONF 2B] driver returned: {ok_off}")
        all_ok = all_ok and ok_off
        time.sleep(2)
        
        if ok_on and ok_off:
            print("  [SUCCESS] NETCONF Hardware Driver stage completed.")
        else:
            print("  [FAIL] NETCONF stage reported at least one hardware failure.")

    except Exception as e:
        print(f"  [ERROR] NETCONF Hardware Test failed: {e}")
        all_ok = False

    print("\n==================================================")
    if all_ok:
        print("   Universal Hardware Test Sequence Complete      ")
    else:
        print("   Test Sequence Finished With Failures           ")
    print("==================================================")


if __name__ == "__main__":
    run_hardware_test()
