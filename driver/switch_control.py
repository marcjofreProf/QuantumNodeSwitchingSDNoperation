import json
import time
import logging
import gpiod

class OpticalMatrixDriver:
    def __init__(self, config_path="driver/pin_mappings.json"):
        self.logger = logging.getLogger("OpticalMatrixDriver")
        logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
        
        self.logger.info(f"Loading switch configuration from {config_path}...")
        self.config = self._load_config(config_path)
        self.gpio_map = self.config.get("gpio_port_map", {})
        
        # Extract pin numbers
        self.port_a_pin = self.gpio_map.get("port_A_in")
        self.port_b_pin = self.gpio_map.get("port_B_out")
        self.strobe_pin = self.gpio_map.get("strobe_pin")
        
        self._init_gpio()

    def _load_config(self, path):
        try:
            with open(path, 'r') as f:
                return json.load(f)
        except Exception as e:
            self.logger.error(f"Failed to load pin mappings: {e}")
            raise

    def _init_gpio(self):
        """Initializes the GPIO lines using libgpiod."""
        self.logger.info("Initializing GPIO lines via libgpiod...")
        try:
            self.line_a = self._get_gpiod_line(self.port_a_pin)
            self.line_b = self._get_gpiod_line(self.port_b_pin)
            self.line_strobe = self._get_gpiod_line(self.strobe_pin)

            self.line_a.request(consumer="quantum_sdn", type=gpiod.LINE_REQ_DIR_OUT)
            self.line_b.request(consumer="quantum_sdn", type=gpiod.LINE_REQ_DIR_OUT)
            self.line_strobe.request(consumer="quantum_sdn", type=gpiod.LINE_REQ_DIR_OUT)
            
            self.line_a.set_value(0)
            self.line_b.set_value(0)
            self.line_strobe.set_value(0)
            
            self.logger.info("GPIO initialization complete. Default states set to LOW.")
        except Exception as e:
            self.logger.error(f"Hardware GPIO setup failed. Error: {e}")

    def _get_gpiod_line(self, flat_pin):
        """Converts a flat pin number to a libgpiod line object."""
        chip_num = flat_pin // 32
        line_offset = flat_pin % 32
        chip = gpiod.Chip(f"gpiochip{chip_num}")
        return chip.get_line(line_offset)

    def trigger_crossconnect(self, state: bool):
        """Executes the switching logic for the MEMS Optical Matrix."""
        val = 1 if state else 0
        action = "CONNECTING" if state else "DISCONNECTING"
        self.logger.info(f"{action} optical path (Port A: {self.port_a_pin}, Port B: {self.port_b_pin})...")
        
        try:
            self.line_a.set_value(val)
            self.line_b.set_value(val)
            
            time.sleep(0.01) # Settle time
            self.line_strobe.set_value(1)
            time.sleep(0.05) # Strobe duration (50ms)
            self.line_strobe.set_value(0)
            
            self.logger.info("Matrix transition latched successfully.")
            return True
        except Exception as e:
            self.logger.error(f"Hardware failure during matrix transition: {e}")
            return False

    def release(self):
        """Releases the GPIO lines back to the OS."""
        self.logger.info("Releasing GPIO lines...")
        self.line_a.release()
        self.line_b.release()
        self.line_strobe.release()
