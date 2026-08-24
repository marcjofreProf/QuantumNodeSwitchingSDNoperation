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
if prompt_yes_no "Phase 1: Stop and remove systemd services (quantum-gnoi-agent, quantum-netconf-agent)?"; then
    log_info "Stopping and disabling agent services..."
    sudo systemctl stop quantum-gnoi-agent quantum-netconf-agent 2>/dev/null || true
    sudo systemctl disable quantum-gnoi-agent quantum-netconf-agent 2>/dev/null || true

    # Clean up gNOI service
    if [ -L "/etc/systemd/system/quantum-gnoi-agent.service" ] || [ -f "/etc/systemd/system/quantum-gnoi-agent.service" ]; then
        log_info "Removing gNOI systemd service symlink..."
        sudo rm -f /etc/systemd/system/quantum-gnoi-agent.service
    fi

    # Clean up NETCONF service
    if [ -L "/etc/systemd/system/quantum-netconf-agent.service" ] || [ -f "/etc/systemd/system/quantum-netconf-agent.service" ]; then
        log_info "Removing NETCONF systemd service symlink..."
        sudo rm -f /etc/systemd/system/quantum-netconf-agent.service
    fi

    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    log_success "Systemd services removed."
fi

# --- Phase 2: Python Virtual Environment Cleanup ---
if prompt_yes_no "Phase 2: Remove Python virtual environment (./venv)?"; then
    if [ -L "venv" ] || [ -d "venv" ]; then
        log_info "Removing local ./venv link/directory..."
        rm -rf venv
    fi
    
    if [ -d "/mnt/sdcard/venv" ]; then
        log_info "Removing offloaded SD card venv (/mnt/sdcard/venv)..."
        sudo rm -rf /mnt/sdcard/venv
    fi
    
    log_success "Virtual environment completely removed."
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
        # Count total default routes active on the system
        total_default_routes=$(ip route show | grep -c "^default")

        if [ "$total_default_routes" -gt 1 ]; then
            log_info "Multiple default routes detected. Safely removing fallback route via 10.0.0.1..."
            sudo ip route del default via 10.0.0.1 || true
            log_success "Fallback route removed."
        else
            log_warn "Route 10.0.0.1 is the ONLY active default route on this node."
            log_warn "Skipping deletion to prevent losing network/internet connectivity."
        fi
    else
        log_info "Fallback route 10.0.0.1 is not currently active."
    fi
fi

# --- Phase 5: Optional APT Package Purge ---
if prompt_yes_no "Phase 5: Purge build dependencies (golang-go, protobuf-compiler, gpiod, libgpiod-dev)?"; then
    log_info "Purging packages..."
    sudo apt-get purge -y golang-go protobuf-compiler gpiod libgpiod-dev python3-libgpiod || true
    sudo apt-get autoremove -y
    log_success "Packages purged."
fi

# --- Phase 6: Restore APT Cache to Internal eMMC ---
if prompt_yes_no "Phase 6: Restore APT cache to internal eMMC (Crucial if removing the SD card)?"; then
    if [ -L "/var/cache/apt/archives" ]; then
        log_info "Removing APT cache symlink pointing to SD card..."
        sudo rm -f /var/cache/apt/archives
        
        log_info "Recreating default internal APT cache directories..."
        sudo mkdir -p /var/cache/apt/archives/partial
        sudo chown -R _apt:root /var/cache/apt/archives
        sudo apt-get clean
        
        log_success "APT cache safely unlinked and restored to eMMC."
    else
        log_info "APT cache is not symlinked. Skipping."
    fi
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown Complete! Repository files preserved. ${NC}"
echo -e "${GREEN}====================================================${NC}"
