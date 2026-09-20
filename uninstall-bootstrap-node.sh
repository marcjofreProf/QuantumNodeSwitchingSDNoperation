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

log_info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn()    { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error()   { echo -e "${RED}[ERROR] $1${NC}"; }

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

# ---------------------------------------------------------------------------
# --- Phase 1: Systemd Service Cleanup ---
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 1: Stop and remove systemd services (quantum-grpc-agent, quantum-netconf-agent)?"; then
    log_info "Stopping and disabling agent services..."
    sudo systemctl stop    quantum-grpc-agent quantum-netconf-agent quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true
    sudo systemctl disable quantum-grpc-agent quantum-netconf-agent quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true

    if [ -L "/etc/systemd/system/quantum-grpc-agent.service" ] || [ -f "/etc/systemd/system/quantum-grpc-agent.service" ]; then
        log_info "Removing unified gRPC systemd service..."
        sudo rm -f /etc/systemd/system/quantum-grpc-agent.service
    fi

    # Clean up legacy gNMI / gNOI services if present
    sudo rm -f /etc/systemd/system/quantum-gnmi-agent.service /etc/systemd/system/quantum-gnoi-agent.service

    if [ -L "/etc/systemd/system/quantum-netconf-agent.service" ] || [ -f "/etc/systemd/system/quantum-netconf-agent.service" ]; then
        log_info "Removing NETCONF systemd service..."
        sudo rm -f /etc/systemd/system/quantum-netconf-agent.service
    fi

    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    log_success "Systemd services removed."
fi

# ---------------------------------------------------------------------------
# --- Phase 2: Python Virtual Environment Cleanup ---
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# --- Phase 3: Clean Generated Stubs & Log Symlink ---
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 3: Clean compiled gRPC stubs and log symlinks (preserves source code)?"; then
    log_info "Removing compiled Python gRPC stubs..."
    rm -f proto/*_pb2*.py proto/*_pb2_grpc.py

    if [ -L "logs" ]; then
        log_info "Removing logs symlink..."
        rm -f logs
    fi
    log_success "Compiled stubs and temporary log symlink removed."
fi

# ---------------------------------------------------------------------------
# --- Phase 4: Network Configuration Teardown ---
# Reverses bootstrap Phase 6 (persistent MANO network config).
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 4: Remove MANO network config (interfaces.d entry, resolv.conf)?"; then
    IFACE_CONF="/etc/network/interfaces.d/quantum-node"

    if [ -f "$IFACE_CONF" ]; then
        log_info "Removing persistent interface config $IFACE_CONF..."
        # Report what we are removing so the operator knows what was set
        grep -E "^\s*(address|gateway|hwaddress|dns-nameservers)" "$IFACE_CONF" 2>/dev/null | sed 's/^/    /'
        sudo rm -f "$IFACE_CONF"
    else
        log_info "No $IFACE_CONF present."
    fi

    # Remove the source line we added, but only if interfaces.d is now empty
    # (matches both "source" and "source-directory" forms)
    if [ -f /etc/network/interfaces ] && \
       grep -qE '^source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces; then
        if [ -z "$(ls -A /etc/network/interfaces.d 2>/dev/null)" ]; then
            log_info "interfaces.d is empty; removing the source line we added..."
            sudo sed -i -E '/^source(-directory)?[[:space:]]+\/etc\/network\/interfaces\.d/d' /etc/network/interfaces
        else
            log_warn "interfaces.d still contains other files; leaving source line in place."
        fi
    fi

    # Restore resolv.conf to plain public DNS (the controller DNS is gone)
    log_info "Restoring /etc/resolv.conf to public DNS..."
    sudo rm -f /etc/resolv.conf
    sudo tee /etc/resolv.conf > /dev/null <<EOF
# Restored by uninstall-bootstrap-node.sh
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    log_success "MANO network configuration removed."
fi

# ---------------------------------------------------------------------------
# --- Phase 5: Network Route Fallback Cleanup ---
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 5: Remove fallback default route (10.0.0.1) if active?"; then
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

# ---------------------------------------------------------------------------
# --- Phase 6: Optional APT Package Purge ---
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 6: Purge build dependencies (golang-go, protobuf-compiler, gpiod, libgpiod-dev)?"; then
    log_info "Purging packages..."
    sudo apt-get purge -y golang-go protobuf-compiler gpiod libgpiod-dev python3-libgpiod || true
    sudo apt-get autoremove -y
    log_success "Packages purged."
fi

# ---------------------------------------------------------------------------
# --- Phase 7: Restore APT Cache to Internal eMMC ---
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 7: Restore APT cache to internal eMMC (Crucial if removing the SD card)?"; then
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

# ---------------------------------------------------------------------------
# --- Phase 8: SD Card Unmount & fstab Cleanup ---
# Reverses bootstrap Phase 0.8. Fixes the "connectivity lost after reboot
# with SD attached" symptom by removing the fstab entry that can stall boot.
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 8: Unmount SD card and remove its fstab entry?"; then
    # 1) Remove fstab entry FIRST so nothing tries to remount the SD later
    if grep -q "/mnt/sdcard" /etc/fstab; then
        log_info "Removing /mnt/sdcard entry from /etc/fstab..."
        sudo cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
        sudo sed -i '\|\s/mnt/sdcard\s|d' /etc/fstab
        log_success "fstab cleaned (backup saved as /etc/fstab.bak.*)."
    else
        log_info "No /mnt/sdcard entry in /etc/fstab."
    fi

    # 2) Clean bootstrap-created directories BEFORE unmounting
    if mountpoint -q /mnt/sdcard; then
        log_info "Removing bootstrap-created directories on SD card..."
        sudo rm -rf /mnt/sdcard/quantum_logs /mnt/sdcard/apt-cache
    fi

    # 3) Unmount LAST
    if mountpoint -q /mnt/sdcard; then
        log_info "Unmounting /mnt/sdcard..."
        sudo umount /mnt/sdcard 2>/dev/null || sudo umount -l /mnt/sdcard 2>/dev/null || true
        log_success "/mnt/sdcard unmounted."
    else
        log_info "/mnt/sdcard is not mounted."
    fi

    # NOTE: no daemon-reload here — Phase 1 already removed the units.
fi

# ---------------------------------------------------------------------------
# --- Phase 9: Remove dpkg doc/locale exclusions ---
# Reverses bootstrap Phase 0.7 so future installs get docs back.
# ---------------------------------------------------------------------------
if prompt_yes_no "Phase 9: Remove dpkg no-doc / no-locale exclusions (restore docs on next install)?"; then
    if [ -f /etc/dpkg/dpkg.cfg.d/01_nodoc ]; then
        log_info "Removing /etc/dpkg/dpkg.cfg.d/01_nodoc..."
        sudo rm -f /etc/dpkg/dpkg.cfg.d/01_nodoc
        log_success "dpkg exclusions removed. Re-installing existing packages will restore their docs."
    else
        log_info "No /etc/dpkg/dpkg.cfg.d/01_nodoc present. Skipping."
    fi
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown Complete! Repository files preserved. ${NC}"
echo -e "${GREEN}====================================================${NC}"

# ---------------------------------------------------------------------------
# --- Phase 10: Reboot to apply network/fstab changes ---
# ---------------------------------------------------------------------------
log_warn "Network and fstab changes only take effect after a reboot."
if prompt_yes_no "Reboot now to apply the teardown changes?"; then
    log_info "Flushing buffers and rebooting..."
    sync
    sleep 3
    log_warn "If this is a remote SSH session, it will now disconnect."
    sleep 2
    sudo reboot -f
else
    log_info "Reboot skipped. Please reboot manually when convenient."
fi
