#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Safe Teardown & Uninstall Script
# Reverses node bootstrap changes without deleting repository source code
#
# Matches bootstrap-node.sh: venv on local eMMC, logs and
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
    log_info "Phase 2: Removing Python virtual environment..."
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
# --- Phase 4: Network Configuration (preserved, with one exception) ---
#
# The teardown does not modify the host's network configuration. The
# interface settings and static routes written by the bootstrap are left
# in place so the node stays reachable and no reboot is required.
#
# The one exception is the immutable attribute the bootstrap sets on
# /etc/resolv.conf. That attribute would otherwise block any future
# manual edit or re-provisioning, so it is cleared here even though the
# file's contents are left untouched.
# ---------------------------------------------------------------------------
log_info "Phase 4: Network configuration preserved."
log_info "  (Set RESTORE_NETWORK=1 to revert /etc/network/interfaces on teardown.)"

if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    log_info "Clearing immutable attribute on /etc/resolv.conf..."
    if ! sudo chattr -i /etc/resolv.conf 2>/dev/null; then
        log_warn "Failed to clear immutable attribute on /etc/resolv.conf."
        log_warn "  The file is on a filesystem that does not support chattr,"
        log_warn "  or the operation was refused. Manually check with:"
        log_warn "    lsattr /etc/resolv.conf"
    fi
fi

# ---------------------------------------------------------------------------
# --- Phase 5: Fallback Route (intentionally preserved) ---
# The fallback default route added by the bootstrap during its run is
# session-only and does not persist. It is not removed here because the
# teardown does not modify live network state.
# ---------------------------------------------------------------------------
log_info "Phase 5: Fallback route preserved (not modified)."

# ---------------------------------------------------------------------------
# --- Phase 6: Restore APT Cache to Internal eMMC ---
#
# This MUST run before any apt operation. The bootstrap may have left
# /var/cache/apt/archives as a symlink to /mnt/sdcard/apt-cache. If the
# SD card is not mounted, that symlink is dangling and every apt command
# fails with "Archives directory ... missing". Restoring the local
# directory first makes the following purge step actually work.
# ---------------------------------------------------------------------------
log_info "Phase 6: Restoring APT cache to internal eMMC..."
if [ -L "/var/cache/apt/archives" ]; then
    log_info "Removing APT cache symlink pointing to SD card..."
    sudo rm -f /var/cache/apt/archives
fi

# Recreate the directory whether it was a broken symlink or simply missing.
if [ ! -d "/var/cache/apt/archives/partial" ]; then
    log_info "Recreating default internal APT cache directories..."
    sudo mkdir -p /var/cache/apt/archives/partial
    sudo chown -R _apt:root /var/cache/apt/archives
fi
log_success "APT cache restored to eMMC."

# ---------------------------------------------------------------------------
# --- Phase 7: Purge Build Dependencies ---
#
# Runs after Phase 6 so apt has a working archives directory.
#
# APT::Get::AutomaticRemove=false and APT::Get::Remove=false disable
# apt's cascade behaviour: only the named packages are removed. Without
# these, purging gpiod also drags out bb-cape-overlays (its dependency on
# the RCN-EE kernel), and purging golang-go / protobuf-compiler drags out
# their nine library dependencies. On a dedicated node that is harmless,
# but on a reused BeagleBone it can silently remove packages another
# project needs.
# ---------------------------------------------------------------------------
log_info "Phase 7: Purging build dependencies..."

# APT::Get::AutomaticRemove=false prevents apt from also removing the
# packages that were only pulled in as dependencies of the ones we are
# purging. That is the desired "no cascade" behaviour.
#
# Do NOT add `APT::Get::Remove=false`: that flag disables the remove
# operation entirely and produces the error
#   "E: Packages need to be removed but remove is disabled."
#
# The purge will still remove bb-cape-overlays if it depends on gpiod —
# apt must remove a package whose dependency is being purged, or the
# package state would be inconsistent. That is unavoidable without
# excluding gpiod from the purge list.
if sudo apt-get purge -y \
        -o APT::Get::AutomaticRemove=false \
        golang-go protobuf-compiler; then
    log_success "Packages purged."
else
    log_warn "Package purge failed; see the apt output above."
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

# ---------------------------------------------------------------------------
# Restore the flasher trigger if it was disabled by the bootstrap.
#
# The bootstrap comments out cmdline=init=/usr/sbin/init-beagle-flasher in
# /boot/uEnv.txt to protect the configuration. On teardown, restoring the
# original line makes the board ready to be reflashed by a future SD card
# if the operator wants to.
# ---------------------------------------------------------------------------
# Restore the flasher trigger ONLY if the user explicitly asks for it.
# The oldest backup is the one from before any bootstrap run, and is the
# only one that actually has the flasher enabled. Silently restoring it
# while the SD card is still inserted can cause the eMMC to be reflashed
# on the next boot.
if [ -f /boot/uEnv.txt ]; then
    oldest_backup=$(ls -tr /boot/uEnv.txt.bak.* 2>/dev/null | head -n1 || true)
    if [ -n "$oldest_backup" ] && [ -f "$oldest_backup" ]; then
        if [ "${RESTORE_FLASHER:-0}" = "1" ]; then
            log_warn "RESTORE_FLASHER=1: restoring flasher trigger from $oldest_backup."
            log_warn "Remove the SD card BEFORE rebooting if you do not want a reflash."
            sudo cp "$oldest_backup" /boot/uEnv.txt
            log_success "uEnv.txt restored (flasher re-enabled)."
        else
            log_info "Flasher trigger left disabled (safer)."
            log_info "  Set RESTORE_FLASHER=1 to re-enable it from $oldest_backup."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# --- Phase 10: Restore original /etc/network/interfaces (optional) ---
# Bootstrap normalises /etc/network/interfaces by commenting out any
# auto/iface block for the primary NIC and appending a single
# source-directory line. That is intentional while the node is being
# managed, but on a full teardown it should be reverted so the host
# behaves like a stock image again.
#
# This is OPT-IN (RESTORE_NETWORK=1) because reverting it can drop the
# SSH session the operator is currently using.
# ---------------------------------------------------------------------------
if [ "${RESTORE_NETWORK:-0}" = "1" ]; then
    IFACE_CONF="/etc/network/interfaces.d/quantum-node"
    if [ -f "${IFACE_CONF}.main.bak" ]; then
        log_warn "RESTORE_NETWORK=1: restoring /etc/network/interfaces from backup."
        sudo cp "${IFACE_CONF}.main.bak" /etc/network/interfaces
        log_success "Restored /etc/network/interfaces."
    fi
    if [ -f "$IFACE_CONF" ]; then
        sudo rm -f "$IFACE_CONF"
        log_success "Removed $IFACE_CONF."
    fi
    if [ -f "/etc/network/.quantum_mac" ]; then
        sudo rm -f "/etc/network/.quantum_mac"
    fi
    log_warn "A reboot is required for the network configuration to revert."
    log_warn "Reconnect after reboot using the interface's DHCP address."
fi
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown Complete! Repository files preserved. ${NC}"
echo -e "${GREEN}====================================================${NC}"
