#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Interactive BBB Bootstrap Script
# ---------------------------------------------------------------------------

set -e # Exit immediately on error

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup ===${NC}"

# --- Phase 0: Network Configuration ---
if prompt_yes_no "Phase 0: Verify/Configure networking for internet access?"; then
    log_info "Checking current routing and internet connectivity..."
    
    # 1. Check if a default route already exists
    if ip route | grep -q "^default"; then
        CURRENT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -n 1)
        log_success "Default route already exists via $CURRENT_GW (Preserving SDN Architecture terminal routing)."
    else
        # 2. Fallback to 10.0.0.1 if no default route exists
        log_info "No default route found. Attempting to set fallback gateway to 10.0.0.1..."
        if ping -c 1 -W 1 10.0.0.1 >/dev/null 2>&1; then
            sudo ip route add default via 10.0.0.1 || true
            log_success "Added default route via 10.0.0.1."
        else
            echo -e "${YELLOW}[WARNING] Gateway 10.0.0.1 is not reachable. You may not have internet connectivity.${NC}"
        fi
    fi

    # 3. Verify actual internet access and fix DNS if needed
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log_info "Internet not reachable. Updating DNS in /etc/resolv.conf..."
        if ! grep -q "8.8.8.8" /etc/resolv.conf; then
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
            log_success "Updated /etc/resolv.conf with public DNS."
        fi
        echo -e "${YELLOW}[NOTE] If internet still fails, ensure your host computer is sharing its connection via NAT/iptables.${NC}"
    else
        log_success "Internet connectivity verified!"
    fi
fi

# --- Phase 1: System Updates ---
if prompt_yes_no "Phase 1: Update system packages (apt-get update)?"; then
    log_info "Updating BeagleBone Black package repositories..."
    sudo apt-get update -y
    sudo apt-get install -y build-essential git curl wget jq systemd
    log_success "System packages updated."
fi

# --- Phase 2: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 2: Install/Reinstall GPIO control libraries (libgpiod)?"; then
    log_info "Installing libgpiod..."
    sudo apt-get install -y gpiod libgpiod-dev python3-libgpiod
    log_success "GPIO libraries installed."
fi

# --- Phase 3: gRPC, Protobuf, and Agent Tooling ---
if prompt_yes_no "Phase 3: Install/Reinstall gRPC, Protobuf, and Python venv?"; then
    log_info "Installing gRPC and Protocol Buffers..."
    sudo apt-get install -y golang-go protobuf-compiler python3-pip python3-venv

    log_info "Setting up Python virtual environment (./venv)..."
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
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To start the agent:  ${YELLOW}sudo systemctl enable --now quantum-gnoi-agent.service${NC}"
echo -e "To view live logs:   ${YELLOW}tail -f logs/agent.log${NC} or ${YELLOW}journalctl -u quantum-gnoi-agent -f${NC}"
echo -e "${GREEN}====================================================${NC}"
