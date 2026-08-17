#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Universal Teardown & Uninstall Script
# Reverses changes made by bootstrap-quantum-switching-sdn.sh
# ---------------------------------------------------------------------------

set +e # Do not exit on individual errors so all cleanup phases can complete

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

if ! prompt_yes_no "Are you sure you want to stop services, unmount SD storage, and clean this node?"; then
    log_info "Teardown cancelled."
    exit 0
fi

# --- Phase 1: Stop and Remove Systemd Service ---
if prompt_yes_no "Phase 1: Stop and disable systemd service (quantum-gnoi-agent)?"; then
    log_info "Stopping and disabling quantum-gnoi-agent service..."
    sudo systemctl stop quantum-gnoi-agent 2>/dev/null || true
    sudo systemctl disable quantum-gnoi-agent 2>/dev/null || true

    if [ -L "/etc/systemd/system/quantum-gnoi-agent.service" ] || [ -f "/etc/systemd/system/quantum-gnoi-agent.service" ]; then
        log_info "Removing systemd unit file..."
        sudo rm -f /etc/systemd/system/quantum-gnoi-agent.service
        sudo systemctl daemon-reload
        sudo systemctl reset-failed
        log_success "Systemd service removed successfully."
    else
        log_info "Systemd service file not found in /etc/systemd/system/."
    fi
fi

# --- Phase 2: Python Virtual Environment Cleanup ---
if prompt_yes_no "Phase 2: Remove Python virtual environment (./venv)?"; then
    if [ -d "venv" ]; then
        log_info "Deleting ./venv directory..."
        rm -rf venv
        log_success "Virtual environment deleted."
    else
        log_info "No ./venv directory found."
    fi
fi

# --- Phase 3: SD Card Mount & fstab Cleanup ---
if prompt_yes_no "Phase 3: Clean up SD Card mount (/mnt/sdcard) and fstab entries?"; then
    # Remove from /etc/fstab
    if grep -q "/mnt/sdcard" /etc/fstab 2>/dev/null; then
        log_info "Removing /mnt/sdcard entry from /etc/fstab..."
        sudo sed -i '\|/mnt/sdcard|d' /etc/fstab
        log_success "fstab updated."
    fi

    # Unmount if mounted
    if mountpoint -q /mnt/sdcard 2>/dev/null; then
        log_info "Unmounting /mnt/sdcard..."
        sudo umount /mnt/sdcard
        log_success "SD card unmounted."
    fi

    if [ -d "/mnt/sdcard" ]; then
        log_info "Removing mount directory /mnt/sdcard..."
        sudo rm -rf /mnt/sdcard
    fi
fi

# --- Phase 4: Network Route Fallback Cleanup ---
if prompt_yes_no "Phase 4: Check and remove fallback default route (10.0.0.1) if present?"; then
    if ip route show | grep -q "default via 10.0.0.1"; then
        log_info "Removing route default via 10.0.0.1..."
        sudo ip route del default via 10.0.0.1 || true
        log_success "Fallback route removed."
    else
        log_info "No default route via 10.0.0.1 detected."
    fi
fi

# --- Phase 5: Optional APT Package Purge ---
if prompt_yes_no "Phase 5: Purge installed hardware and development packages (golang-go, protobuf-compiler, gpiod, libgpiod-dev)?"; then
    log_info "Purging packages..."
    sudo apt-get purge -y golang-go protobuf-compiler gpiod libgpiod-dev python3-libgpiod || true
    sudo apt-get autoremove -y
    log_success "Development and GPIO packages purged."
fi

# --- Phase 6: Clean Repository Folder Structure ---
if prompt_yes_no "Phase 6: Wipe generated folders (agent, driver, proto, systemd, test, logs) and non-tracked files?"; then
    if [ -d ".git" ]; then
        log_info "Git repository detected. Performing hard reset and cleaning non-tracked files..."
        git clean -fdx
        git reset --hard HEAD
        log_success "Repository completely restored to clean Git state."
    else
        log_info "Removing scaffolded directories..."
        rm -rf agent driver proto systemd test logs venv
        log_success "Directories cleaned."
    fi
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown and Node Cleanup Complete! ${NC}"
echo -e "${GREEN}====================================================${NC}"
