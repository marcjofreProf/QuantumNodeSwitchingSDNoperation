#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Safe Teardown & Uninstall Script
# Reverses node bootstrap changes without deleting repository source code
#
# Matches bootstrap-node.sh "Design B": venv on local eMMC, logs and
# apt-cache opportunistically on the SD. Safe to run whether or not the
# SD card is mounted.
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

# Teardown runs non-interactively: every prompt is auto-answered "yes".
prompt_yes_no() {
    return 0
}

echo -e "${RED}===========================================================${NC}"
echo -e "${RED}    Quantum Node Switching Agent Teardown & Cleanup        ${NC}"
echo -e "${RED}===========================================================${NC}"

log_info "All teardown actions will proceed automatically. Network configuration will be preserved."

# ---------------------------------------------------------------------------
# --- Phase 1: Systemd Service Cleanup ---
# ---------------------------------------------------------------------------
log_info "Phase 1: Stopping and removing systemd services..."
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

# Remove the SD-wait guard if present. Design B does not install it, but
# a previous Design A install may have left it behind.
if [ -f "/etc/systemd/system/wait-sdcard.service" ]; then
    log_info "Removing leftover wait-sdcard systemd service..."
    sudo systemctl stop    wait-sdcard.service 2>/dev/null || true
    sudo systemctl disable wait-sdcard.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/wait-sdcard.service
fi

sudo systemctl daemon-reload
sudo systemctl reset-failed
log_success "Systemd services removed."


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

    # Remove the downloaded ONF gNMI proto sources and any nested stub
    # tree left over from older bootstrap versions. Also removes the legacy
    # custom gNMI proto (see below).
    rm -f proto/gnmi.proto
    rm -f proto/gnmi_ext.proto
    rm -rf proto/github
    rm -rf proto/github.com

    # Remove the legacy custom gNMI proto and its stubs. bootstrap-node.sh
    # no longer generates them (the agents use the standard OpenConfig
    # gnmi.proto instead), so clean up any copies left from older runs.
    rm -f proto/quantum_gnmi_switching.proto
    rm -f proto/quantum_gnmi_switching_pb2.py
    rm -f proto/quantum_gnmi_switching_pb2_grpc.py

    if [ -L "logs" ]; then
        log_info "Removing logs symlink..."
        rm -f logs
    fi

    if [ -d "/mnt/sdcard/quantum_logs" ]; then
        log_info "Removing offloaded SD card logs (/mnt/sdcard/quantum_logs)..."
        sudo rm -rf /mnt/sdcard/quantum_logs
    fi

    log_success "Compiled stubs and temporary log symlink removed."
fi

# ---------------------------------------------------------------------------
# --- Phase 4: Network Configuration (intentionally preserved) ---
#
# The teardown does not modify the host's network configuration. The
# interface settings, static routes, and /etc/resolv.conf written by the
# bootstrap are left in place so the node stays reachable and no reboot
# is required. Re-running the bootstrap will overwrite them if needed.
# ---------------------------------------------------------------------------
log_info "Phase 4: Network configuration preserved (not modified)."

# ---------------------------------------------------------------------------
# --- Phase 5: Fallback Route (intentionally preserved) ---
# The fallback default route added by the bootstrap during its run is
# session-only and does not persist. It is not removed here because the
# teardown does not modify live network state.
# ---------------------------------------------------------------------------
log_info "Phase 5: Fallback route preserved (not modified)."

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

    # 2) Clean bootstrap-created directories BEFORE unmounting.
    #    Also remove any local symlinks that point into the SD, so we don't
    #    leave dangling references after the SD is gone.
    if mountpoint -q /mnt/sdcard; then
        log_info "Removing bootstrap-created directories on SD card..."
        sudo rm -rf /mnt/sdcard/quantum_logs /mnt/sdcard/apt-cache
    fi

    # Remove dangling venv/logs symlinks (they will be recreated by the
    # bootstrap as real local directories if it runs again).
    if [ -L "venv" ]; then
        log_info "Removing venv symlink..."
        rm -f venv
    fi
    if [ -L "logs" ]; then
        log_info "Removing logs symlink..."
        rm -f logs
    fi

    # 3) Unmount LAST
    if mountpoint -q /mnt/sdcard; then
        log_info "Unmounting /mnt/sdcard..."
        sudo umount /mnt/sdcard 2>/dev/null || sudo umount -l /mnt/sdcard 2>/dev/null || true
        log_success "/mnt/sdcard unmounted."
    else
        log_info "/mnt/sdcard is not mounted."
    fi
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

    # Clear pip caches that the bootstrap's Phase 0.7 excluded. These are
    # user-level caches, so no sudo needed for the user's own.
    log_info "Clearing pip caches..."
    rm -rf "$HOME/.cache/pip" 2>/dev/null || true
    sudo rm -rf /root/.cache/pip 2>/dev/null || true
    log_success "pip caches cleared."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown Complete! Repository files preserved. ${NC}"
echo -e "${GREEN}====================================================${NC}"
