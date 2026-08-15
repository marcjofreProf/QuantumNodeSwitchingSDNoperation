#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Interactive BBB Bootstrap Script (Bypass APT VENV)
# ---------------------------------------------------------------------------

set -e # Exit immediately on error

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- Helper Functions ---
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

prompt_yes_no() {
    while true; do
        read -p "$1 [y/N]: " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup ===${NC}"

# --- Phase 0: Network Configuration ---
if prompt_yes_no "Phase 0: Verify internet connectivity (Prioritize MANO; Fallback to 10.0.0.1)?"; then
    log_info "Checking if priority path is already operative..."
    if ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log_success "External connectivity verified (Preserving ETSI MANO path)."
    else
        log_warn "Ping check failed. Attempting fallback to 10.0.0.1..."
        if ping -c 1 -W 1 10.0.0.1 > /dev/null 2>&1; then
            sudo ip route add default via 10.0.0.1 || true
            log_success "Fallback default route via 10.0.0.1 added."
        else
            log_error "Gateway 10.0.0.1 not reachable. You may lack internet."
        fi
    fi

    if ! grep -q "8.8.8.8" /etc/resolv.conf; then
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
        log_success "Resolv.conf updated with public DNS."
    fi
fi

# --- Phase 1: System Updates ---
if prompt_yes_no "Phase 1: Update system packages (apt-get update)?"; then
    log_info "Updating package lists..."
    sudo apt-get update -y
    
    log_info "Installing system tools..."
    # Note: python3-venv is REMOVED from this list to prevent the deb10u5 error
    sudo apt-get install -y build-essential git curl wget jq systemd python3-pip
    log_success "System tools updated."
fi

# --- Phase 2: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 2: Install GPIO control libraries (libgpiod)?"; then
    log_info "Installing libgpiod..."
    sudo apt-get install -y gpiod libgpiod-dev python3-libgpiod
    log_success "GPIO libraries installed."
fi

# --- Phase 3: gRPC, Protobuf, and VirtualEnv (THE FIX) ---
if prompt_yes_no "Phase 3: Install gRPC, Protobuf, and Python environment?"; then
    log_info "Installing gRPC and Protocol Buffers..."
    sudo apt-get install -y golang-go protobuf-compiler

    log_info "Installing VirtualEnv via PIP (Bypassing broken APT packages)..."
    sudo pip3 install virtualenv

    log_info "Setting up Python virtual environment (./venv)..."
    rm -rf venv
    virtualenv venv  # Using virtualenv instead of python3 -m venv
    
    source venv/bin/activate
    pip install --upgrade pip
    pip install grpcio grpcio-tools protobuf
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
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To tail live agent logs: ${YELLOW}tail -f logs/agent.log${NC}"
echo -e "Or use journalctl: ${YELLOW}journalctl -u quantum-gnoi-agent -f${NC}"
echo -e "${GREEN}====================================================${NC}"
