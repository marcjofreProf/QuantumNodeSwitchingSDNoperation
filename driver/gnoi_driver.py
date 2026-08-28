import json
import os
import time
import logging
import gpiod

class OpticalMatrixDriver:
    def __init__(self, config_path="driver/gnoi_pin_mappings.json"):
        self.logger = logging.getLogger("OpticalMatrixDriver")
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
        
        self.config_path = config_path
        self.logger.info(f"Loading switch configuration from {config_path}...")
        self.config = self._load_config(config_path)
        self.gpio_map = self.config.get("gpio_port_map", {})
        
        # Extract pin configurations (supports 3-pin or 4-pin layouts)
        self.port_a_pin = self.gpio_map.get("port_A_in")
        self.port_b_pin = self.gpio_map.get("port_B_out")
        self.strobe_pin = self.gpio_map.get("strobe_pin")
        self.enable_pin = self.gpio_map.get("enable_pin")

    def _load_config(self, path):
        """Loads pin configuration from the linked JSON file."""
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    return json.load(f)
            except Exception as e:
                self.logger.error(f"Failed to load pin mappings from {path}: {e}")
                raise
        self.logger.warning(f"Config path {path} not found. Using fallback defaults.")
        return {
            "switch_type": "MEMS-Optical",
            "gpio_port_map": {"port_A_in": 60, "port_B_out": 48, "strobe_pin": 49}
        }

    def _get_gpiod_line(self, pin_spec):
        """
        Converts pin specification to a libgpiod line object.
        Supports flat pin integers (BBB) and dict mappings (BB AI-64).
        """
        if isinstance(pin_spec, dict):
            chip = gpiod.Chip(pin_spec["chip"])
            return chip.get_line(pin_spec["line"])
        
        chip_num = pin_spec // 32
        line_offset = pin_spec % 32
        chip = gpiod.Chip(f"gpiochip{chip_num}")
        return chip.get_line(line_offset)

    def trigger_crossconnect(self, state: bool) -> bool:
        """Executes switching logic with ephemeral GPIO requests to prevent resource locks."""
        val = 1 if state else 0
        action = "CONNECTING" if state else "DISCONNECTING"
        self.logger.info(f"{action} optical path via gNOI...")
        
        requested_lines = []
        try:
            # 1. Set Port A
            if self.port_a_pin is not None:
                line_a = self._get_gpiod_line(self.port_a_pin)
                line_a.request(consumer="quantum_gnoi", type=gpiod.LINE_REQ_DIR_OUT)
                requested_lines.append(line_a)
                line_a.set_value(val)

            # 2. Set Port B
            if self.port_b_pin is not None:
                line_b = self._get_gpiod_line(self.port_b_pin)
                line_b.request(consumer="quantum_gnoi", type=gpiod.LINE_REQ_DIR_OUT)
                requested_lines.append(line_b)
                line_b.set_value(val)

            # 3. Set Enable Pin (if present in config)
            if self.enable_pin is not None:
                line_enable = self._get_gpiod_line(self.enable_pin)
                line_enable.request(consumer="quantum_gnoi", type=gpiod.LINE_REQ_DIR_OUT)
                requested_lines.append(line_enable)
                line_enable.set_value(val)

            # 4. Pulse Strobe Pin (if present in config)
            if self.strobe_pin is not None:
                line_strobe = self._get_gpiod_line(self.strobe_pin)
                line_strobe.request(consumer="quantum_gnoi", type=gpiod.LINE_REQ_DIR_OUT)
                requested_lines.append(line_strobe)
                
                time.sleep(0.01)  # Hardware settle time
                line_strobe.set_value(1)
                time.sleep(0.05)  # 50ms pulse
                line_strobe.set_value(0)

            self.logger.info("Matrix transition latched successfully.")
            return True

        except Exception as e:
            self.logger.error(f"Hardware failure during matrix transition: {e}")
            return False

        finally:
            # Always release lines so NETCONF or other commands can access them
            for line in requested_lines:
                try:
                    line.release()
                except Exception as rel_err:
                    self.logger.warning(f"Error releasing GPIO line: {rel_err}")

    def release(self):
        """Backward compatibility stub for cleanup calls."""
        pass
