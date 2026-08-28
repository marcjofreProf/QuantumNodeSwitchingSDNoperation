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
        
        self._init_gpio()

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
        """Converts flat integer pins (BBB) or dict mappings (BB AI-64) to a libgpiod line object."""
        if isinstance(pin_spec, dict):
            chip = gpiod.Chip(pin_spec["chip"])
            return chip.get_line(pin_spec["line"])
        
        chip_num = pin_spec // 32
        line_offset = pin_spec % 32
        chip = gpiod.Chip(f"gpiochip{chip_num}")
        return chip.get_line(line_offset)

    def _init_gpio(self):
        try:
            self.line_a = self._get_gpiod_line(self.port_a_pin) if self.port_a_pin else None
            self.line_b = self._get_gpiod_line(self.port_b_pin) if self.port_b_pin else None
            self.line_strobe = self._get_gpiod_line(self.strobe_pin) if self.strobe_pin else None

            if self.line_a:
                self.line_a.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                self.line_a.set_value(0)
            if self.line_b:
                self.line_b.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                self.line_b.set_value(0)
            if self.line_strobe:
                self.line_strobe.request(consumer="quantum_netconf", type=gpiod.LINE_REQ_DIR_OUT)
                self.line_strobe.set_value(0)
            logger.info("[NETCONF HAL] Hardware GPIO initialized successfully.")
        except Exception as e:
            logger.error(f"[NETCONF HAL] Hardware GPIO initialization failed: {e}")
            raise RuntimeError(f"NETCONF Hardware Init Failed: {e}")

    def set_netconf_switch_state(self, state: bool) -> bool:
        val = 1 if state else 0
        try:
            logger.info(f"[NETCONF HAL] Setting switch state to {state}...")
            if self.line_a:
                self.line_a.set_value(val)
            if self.line_b:
                self.line_b.set_value(val)
            if self.line_strobe:
                time.sleep(0.01)
                self.line_strobe.set_value(1)
                time.sleep(0.05)
                self.line_strobe.set_value(0)
            return True
        except Exception as e:
            logger.error(f"[NETCONF HAL] Execution failed: {e}")
            return False
