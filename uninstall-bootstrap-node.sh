#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Safe Teardown & Uninstall Script
# Reverses node bootstrap changes without deleting repository source code
# ---------------------------------------------------------------------------

set +e # Do not exit on individual errors

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

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

echo -e "${RED}===========================================================${NC}"
echo -e "${RED}    Quantum Node Switching Agent Teardown & Cleanup        ${NC}"
echo -e "${RED}===========================================================${NC}"

if ! prompt_yes_no "Proceed with stopping node services and cleaning runtime environments?"; then
    log_info "Teardown cancelled."
    exit 0
fi

# --- Phase 1: Systemd Service Cleanup ---
if prompt_yes_no "Phase 1: Stop and remove systemd service (quantum-gnoi-agent)?"; then
    log_info "Stopping and disabling quantum-gnoi-agent service..."
    sudo systemctl stop quantum-gnoi-agent 2>/dev/null || true
    sudo systemctl disable quantum-gnoi-agent 2>/dev/null || true

    if [ -L "/etc/systemd/system/quantum-gnoi-agent.service" ] || [ -f "/etc/systemd/system/quantum-gnoi-agent.service" ]; then
        log_info "Removing systemd service symlink..."
        sudo rm -f /etc/systemd/system/quantum-gnoi-agent.service
        sudo systemctl daemon-reload
        sudo systemctl reset-failed
        log_success "Systemd service removed."
    fi
fi

# --- Phase 2: Python Virtual Environment Cleanup ---
if prompt_yes_no "Phase 2: Remove Python virtual environment (./venv)?"; then
    if [ -d "venv" ]; then
        log_info "Removing ./venv directory..."
        rm -rf venv
        log_success "Virtual environment removed."
    fi
fi

# --- Phase 3: Clean Generated Stubs & Log Symlink ---
if prompt_yes_no "Phase 3: Clean compiled gRPC stubs and log symlinks (preserves source code)?"; then
    log_info "Removing compiled Python gRPC stubs..."
    rm -f proto/*_pb2*.py proto/*_pb2_grpc.py
    
    if [ -L "logs" ]; then
        log_info "Removing logs symlink..."
        rm -f logs
    fi
    log_success "Compiled stubs and temporary log symlink removed."
fi

# --- Phase 4: Network Route Fallback Cleanup ---
if prompt_yes_no "Phase 4: Remove fallback default route (10.0.0.1) if active?"; then
    if ip route show | grep -q "default via 10.0.0.1"; then
        log_info "Removing route default via 10.0.0.1..."
        sudo ip route del default via 10.0.0.1 || true
        log_success "Fallback route removed."
    fi
fi

# --- Phase 5: Optional APT Package Purge ---
if prompt_yes_no "Phase 5: Purge build dependencies (golang-go, protobuf-compiler, gpiod, libgpiod-dev)?"; then
    log_info "Purging packages..."
    sudo apt-get purge -y golang-go protobuf-compiler gpiod libgpiod-dev python3-libgpiod || true
    sudo apt-get autoremove -y
    log_success "Packages purged."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown Complete! Repository files preserved. ${NC}"
echo -e "${GREEN}====================================================${NC}"
