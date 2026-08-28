import json
import os
import logging
import time
import gpiod

logger = logging.getLogger("NetconfHardwareDriver")

class NetconfHardwareDriver:
    def __init__(self, config_path="driver/netconf_pin_mappings.json"):
        self.config_path = config_path
        self.config = self._load_config()
        self.gpio_map = self.config.get("gpio_port_map", {})
        
        self.port_a_pin = self.gpio_map.get("port_A_in") or self.gpio_map.get("enable_pin")
        self.port_b_pin = self.gpio_map.get("port_B_out")
        self.strobe_pin = self.gpio_map.get("strobe_pin")

    def _load_config(self):
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r') as f:
                    return json.load(f)
            except Exception as e:
                logger.error(f"[NETCONF HAL] Error reading {self.config_path}: {e}")
        return {
            "switch_type": "MEMS-Optical",
            "gpio_port_map": {"port_A_in": 60, "port_B_out": 48, "strobe_pin": 49}
        }

    def _get_gpiod_line(self, pin_spec):
        if isinstance(pin_spec, dict):
            chip = gpiod.Chip(pin_spec["chip"])
            return chip.get_line(pin_spec["line"])
        chip_num = pin_spec // 32
        line_offset = pin_spec % 32
        chip = gpiod.Chip(f"gpiochip{chip_num}")
        return chip.get_line(line_offset)

    def set_netconf_switch_state(self, state: bool) -> bool:
        val = 1 if state else 0
        line_a, line_b, line_strobe = None, None, None
        try:
            logger.info(f"[NETCONF HAL] Actuating switch state to {state}...")
            
            # Request lines dynamically
            if self.port_a_pin:
                line_a = self._get_gpiod_line(self.port_a_pin)
                line_a.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                line_a.set_value(val)

            if self.port_b_pin:
                line_b = self._get_gpiod_line(self.port_b_pin)
                line_b.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                line_b.set_value(val)

            if self.strobe_pin:
                line_strobe = self._get_gpiod_line(self.strobe_pin)
                line_strobe.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                time.sleep(0.01)
                line_strobe.set_value(1)
                time.sleep(0.05)
                line_strobe.set_value(0)

            return True
        except Exception as e:
            logger.error(f"[NETCONF HAL] Execution failed: {e}")
            return False
        finally:
            # Always release lines so gNOI or future requests can claim them
            if line_a: line_a.release()
            if line_b: line_b.release()
            if line_strobe: line_strobe.release()
