#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - BeagleBone Black Bootstrap Script
# ---------------------------------------------------------------------------

set -e # Exit immediately on error

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }

# --- 1. System Updates & Base Dependencies ---
log_info "Phase 1: Updating BeagleBone Black package repositories..."
sudo apt-get update -y

log_info "Installing base dependencies..."
sudo apt-get install -y build-essential git curl wget jq systemd

# --- 2. Hardware / GPIO Libraries ---
log_info "Phase 2: Installing GPIO control libraries (libgpiod)..."
# libgpiod is the modern, fast standard for manipulating GPIO on Linux
sudo apt-get install -y gpiod libgpiod-dev python3-libgpiod

# --- 3. gRPC, Protobuf, and Agent Tooling ---
log_info "Phase 3: Installing gRPC and Protocol Buffers..."
# Installing standard Go and Python environments for the gNOI agent
sudo apt-get install -y golang-go protobuf-compiler python3-pip python3-venv

# Set up a Python virtual environment for Python-based gNOI testing/drivers
log_info "Setting up Python virtual environment for gRPC..."
python3 -m venv venv
source venv/bin/activate
pip3 install --upgrade pip
pip3 install grpcio grpcio-tools protobuf
deactivate

# --- 4. Scaffold Repository Structure ---
log_info "Phase 4: Creating node-level folder structure..."
mkdir -p agent
mkdir -p driver
mkdir -p proto
mkdir -p systemd
mkdir -p logs

# Create a placeholder for the pin mappings
cat <<EOF > driver/pin_mappings.json
{
  "switch_type": "MEMS_Optical_Matrix",
  "vendor": "Generic",
  "gpio_port_map": {
    "port_A_in": 68,
    "port_B_out": 69,
    "strobe_pin": 44
  },
  "logic_level": "TTL_3V3_to_5V_Isolated"
}
EOF

# --- 5. Systemd Service Scaffold ---
log_info "Phase 5: Generating Systemd Daemon Configuration..."
cat <<EOF > systemd/quantum-gnoi-agent.service
[Unit]
Description=Quantum SDN gNOI Operations Agent
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
# Update this ExecStart path once the Go/Python agent is compiled
ExecStart=$(pwd)/venv/bin/python3 $(pwd)/agent/main.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log_success "Folder structure and service scaffold generated."

# --- Final Instructions ---
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} BeagleBone Black Node Setup Complete! ${NC}"
echo -e "Next steps:"
echo -e "1. Add your gNOI agent code to the ${YELLOW}./agent${NC} directory."
echo -e "2. Configure physical GPIO pins in ${YELLOW}./driver/pin_mappings.json${NC}."
echo -e "3. Link to systemd: ${YELLOW}sudo ln -s \$(pwd)/systemd/quantum-gnoi-agent.service /etc/systemd/system/${NC}"
echo -e "4. Enable service:  ${YELLOW}sudo systemctl enable --now quantum-gnoi-agent.service${NC}"
echo -e "${GREEN}====================================================${NC}"
