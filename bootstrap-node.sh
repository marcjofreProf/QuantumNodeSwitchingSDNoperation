#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Interactive BBB Bootstrap Script (Fix: PERSISTENT ERRORS)
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
            [Yy]* ) return 0;; # True
            [Nn]* | "" ) return 1;; # False (Default)
            * ) echo "Please answer yes or no.";;
        esac
    done
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup (Fix: Persistent Errors) ===${NC}"

# ===========================================================================
# PHASE 0: Tiered Internet Check (Fix Logic: preserve priority path)
# This implements the logic from Guide 1 in image_2.png
# ===========================================================================
if prompt_yes_no "Phase 0: Verify internet connectivity (Prioritize MANO; Fallback to 10.0.0.1)?"; then
    log_info "Phase 0: Checking if priority path is already operative..."
    
    # Check if we can already reach the internet (e.g., Google DNS)
    if ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log_success "External connectivity verified. Internet is already operative (Preserving ETSI MANO path)."
    else
        log_warn "Ping check failed. Priority path inoperative."
        log_info "Executing fallback command to add default gateway via 10.0.0.1..."
        
        # Check if we can at least reach 10.0.0.1
        if ping -c 1 -W 1 10.0.0.1 > /dev/null 2>&1; then
            sudo ip route add default via 10.0.0.1 || true
            log_success "Fallback default route via 10.0.0.1 added."
        else
            log_error "Gateway 10.0.0.1 not reachable. Cannot add fallback gateway."
            log_warn "You must configure sharing from your host computer now or you will have no internet."
        fi
    fi

    # Update DNS if pinging 8.8.8.8 works but apt-get still fails
    if ! grep -q "8.8.8.8" /etc/resolv.conf; then
        log_info "Ensuring DNS is set to 8.8.8.8 in /etc/resolv.conf..."
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
        log_success "Resolv.conf updated."
    fi
fi
# ===========================================================================

# ===========================================================================
# NEW: PHASE 0.5: Buster Version Mismatch Fix (Aggressive)
# This implements the exact fix sequence from Guide 2 in image_2.png
# Select 'y' for this if Phase 1 previously failed with python3.7 version errors.
# ===========================================================================
if prompt_yes_no "Phase 0.5: Run aggressive Buster mismatch fix (rm apt lists, dist-upgrade, force install venv)?"; then
    log_info "Phase 0.5: Executing aggressive fix sequence from Guide 2 (image_2.png)..."
    
    log_info "1. Wiping stale apt lists and local repository cache..."
    # Force clean repo state and local files
    sudo rm -rf /var/lib/apt/lists/* && sudo apt-get clean
    
    log_info "2. Re-downloading fresh repository meta-data..."
    sudo apt-get update
    
    log_info "3. Performing Buster FULL sync (dist-upgrade) to align version drift..."
    # Standard standard fix for parent/child version drift errors
    sudo apt-get dist-upgrade -y
    
    log_info "4. Confiming dependency path by explicitly installing python3.7-venv..."
    # This confirm install checks that the dependency tree is synced
    sudo apt-get install -y -f python3.7-venv
    
    log_success "Phase 0.5: Parent packages synchronized, and dependency tree fixed. Main installation should succeed."
fi
# ===========================================================================

# --- Phase 1: System Updates ---
if prompt_yes_no "Phase 1: Update system packages (apt-get update)?"; then
    log_info "Updating package lists..."
    sudo apt-get update -y
    
    log_info "Installing system tools and main dependencies..."
    # Full Buster system tools + python3 tools (Buster base)
    sudo apt-get install -y build-essential git curl wget jq systemd python3-pip python3-venv
    log_success "System tools updated."
fi

# --- Phase 2: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 2: Install/Reinstall libgpiod libraries?"; then
    log_info "Installing libgpiod..."
    sudo apt-get install -y gpiod libgpiod-dev python3-libgpiod
    log_success "GPIO libraries installed."
fi

# --- Phase 3: gRPC, Protobuf, and Agent Tooling ---
if prompt_yes_no "Phase 3: Install/Reinstall gRPC, Protobuf, and Python venv?"; then
    log_info "Installing gRPC and Protocol Buffers..."
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
# ExecStart points to the agent within the VENV
ExecStart=$(pwd)/venv/bin/python3 $(pwd)/agent/main.py
Restart=on-failure
RestartSec=5
# Output redirection using append to logs folder artifact
StandardOutput=append:$(pwd)/logs/agent.log
StandardError=append:$(pwd)/logs/agent.log

[Install]
WantedBy=multi-user.target
EOF

    log_info "Linking to /etc/systemd/system/..."
    # Linking ensures the service artifact updates when redeployed
    sudo ln -sf $(pwd)/systemd/quantum-gnoi-agent.service /etc/systemd/system/quantum-gnoi-agent.service
    sudo systemctl daemon-reload
    log_success "Systemd service configured (requires start/enable)."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "Follow the fix guide shown previously if needed."
echo -e "To tail live agent logs: ${YELLOW}tail -f logs/agent.log${NC}"
echo -e "Or use journalctl: ${YELLOW}journalctl -u quantum-gnoi-agent -f${NC}"
echo -e "${GREEN}====================================================${NC}"
