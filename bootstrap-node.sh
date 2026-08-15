#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Interactive BBB Bootstrap Script (Updated)
# ---------------------------------------------------------------------------

set -e # Exit immediately on error

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Helper Functions ---
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
prompt_yes_no() {
    while true; do
        read -p "$1 [y/N]: " yn
        case $yn in
            [Yy]* ) return 0;; # True
            [Nn]* | "" ) return 1;; # False (Default)
            * ) echo "Please answer yes or no.";;
        esac
    done
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup (Updated) ===${NC}"

# --- Phase 0: Network Configuration (assuming 10.0.0.0/24 context) ---
if prompt_yes_no "Phase 0: Configure networking (shared internet access)?"; then
    log_info "Configuring default gateway (assuming host at 10.0.0.1)..."
    sudo ip route add default via 10.0.0.1 || true
    
    log_info "Updating DNS to public providers (8.8.8.8, 1.1.1.1)..."
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
    log_success "Networking configured."
fi

# ===========================================================================
# NEW: Phase 0.5 - Package Manager Fixes (Recommended if Phase 1 fails)
# This executes the sequence shown in image_0.png
# ===========================================================================
if prompt_yes_no "Phase 0.5: Run pre-emptive package manager fixes (clean, fix-broken)?"; then
    log_info "Phase 0.5: Executing package fix sequence from guide..."
    
    log_info "1. Cleaning local apt repository cache..."
    sudo apt-get clean
    sudo apt-get autoclean
    
    log_info "2. Checking for held packages..."
    sudo apt-mark showhold
    
    log_info "3. Attempting to fix broken dependencies explicitly (python3.7-venv Buster fix)..."
    # Forcing install of both python3.7-venv and python3-venv to resolve Buster dependencies
    sudo apt-get install -y -f python3.7-venv python3-venv
    
    log_success "Phase 0.5: Package manager state checked and fixes attempted."
fi
# ===========================================================================

# --- Phase 1: System Updates ---
if prompt_yes_no "Phase 1: Perform system package update and main tool installation?"; then
    log_info "Updating BeagleBone Black package repositories..."
    sudo apt-get update -y
    
    log_info "Installing main system dependencies (git, curl, jq, etc.)..."
    # Basic tools + python3-venv (dependencies should now be met after Phase 0.5)
    sudo apt-get install -y build-essential git curl wget jq systemd python3-pip python3-venv
    log_success "System tools updated."
fi

# --- Phase 2: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 2: Install/Reinstall GPIO control libraries (libgpiod)?"; then
    log_info "Installing libgpiod..."
    sudo apt-get install -y gpiod libgpiod-dev python3-libgpiod
    log_success "GPIO libraries installed."
fi

# --- Phase 3: gRPC, Protobuf, and Agent Tooling ---
if prompt_yes_no "Phase 3: Install/Reinstall gRPC, Protobuf, and Python venv?"; then
    log_info "Installing gRPC and Protocol Buffers compiler..."
    sudo apt-get install -y golang-go protobuf-compiler

    log_info "Setting up Python virtual environment (./venv)..."
    # Overwrite venv if re-deploying
    rm -rf venv
    python3 -m venv venv
    source venv/bin/activate
    pip3 install --upgrade pip
    pip3 install grpcio grpcio-tools protobuf
    deactivate
    log_success "gRPC and Python environment ready."
fi

# --- Phase 4: Scaffold Repository Structure ---
if prompt_yes_no "Phase 4: Generate/Reset directory structure and configs?"; then
    log_info "Creating node-level folder structure..."
    mkdir -p agent driver proto systemd logs

    log_info "Generating default pin_mappings.json..."
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
    log_success "Directories and configurations created."
fi

# --- Phase 5: Systemd Service Scaffold ---
if prompt_yes_no "Phase 5: Generate and install systemd service (quantum-gnoi-agent)?"; then
    log_info "Generating Systemd Configuration..."
    cat <<EOF > systemd/quantum-gnoi-agent.service
[Unit]
Description=Quantum SDN gNOI Operations Agent
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python3 $(pwd)/agent/main.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$(pwd)/logs/agent.log
StandardError=append:$(pwd)/logs/agent.log

[Install]
WantedBy=multi-user.target
EOF

    log_info "Linking to /etc/systemd/system/..."
    sudo ln -sf $(pwd)/systemd/quantum-gnoi-agent.service /etc/systemd/system/quantum-gnoi-agent.service
    sudo systemctl daemon-reload
    log_success "Systemd service configured (requires start/enable)."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete! ${NC}"
echo -e "Follow the fix guide shown previously if needed."
echo -e "${GREEN}====================================================${NC}"
