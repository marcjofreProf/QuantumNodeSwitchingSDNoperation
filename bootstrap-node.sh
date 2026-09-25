#!/bin/bash
# ./bootstrap-node.sh - Smart Auto-Install & Flasher Prevention Script
# ---------------------------------------------------------------------------

set -e

export DEBIAN_FRONTEND=noninteractive

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
        echo -e -n "$1 [y/N]: "
        read yn || true
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local input_value=""
    echo -e -n "${CYAN}${prompt_text}${NC} [${default_value}]: " >&2
    read -r input_value || true
    if [ -z "$input_value" ]; then
        echo "$default_value"
    else
        echo "$input_value"
    fi
}

# Phase gate:
#   - MISSING/unconfigured -> run immediately, NO prompt.
#   - ALREADY installed    -> ask the user whether to re-install.
should_run_phase() {
    local phase_name="$1"
    local is_installed="$2" # 0 = installed/configured, 1 = missing/not configured

    if [ "$is_installed" -eq 1 ]; then
        log_info "$phase_name is missing/unconfigured. Auto-installing (no prompt)..."
        return 0
    fi

    log_warn "$phase_name is already installed and active."
    if prompt_yes_no "Do you want to re-install / re-configure $phase_name?"; then
        return 0
    fi
    log_info "Skipping $phase_name."
    return 1
}

check_and_install() {
    local missing_pkgs=()
    local installed_pkgs=()

    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            installed_pkgs+=("$pkg")
        else
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log_info "Auto-installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --fix-missing "${missing_pkgs[@]}" || log_warn "Some packages failed to install, attempting to proceed..."
    fi

    if [ ${#installed_pkgs[@]} -ne 0 ] && [ "$FORCE_REINSTALL_PKGS" = "true" ]; then
        log_info "Re-installing requested packages: ${installed_pkgs[*]}"
        sudo apt-get install -y --reinstall "${installed_pkgs[@]}" || true
    fi
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup ===${NC}"

# ---------------------------------------------------------------------------
# Design B: the SD card is optional.
#
# The venv is the one thing the agents cannot run without, and it now stays
# on local eMMC. The SD is used opportunistically for logs and the apt
# cache, which are easy to lose and add up on small eMMC. If the SD is
# absent, those simply fall back to local directories.
# ---------------------------------------------------------------------------
if ! mountpoint -q /mnt/sdcard; then
    log_warn "SD card is not mounted at /mnt/sdcard."
    log_warn "Logs and apt cache will stay on local eMMC for this run."
else
    log_success "SD card is mounted at /mnt/sdcard (logs and apt cache will be offloaded)."
fi

ARCH=$(uname -m)
log_info "Detected System Architecture: $ARCH"

# Globals used by Phase 0 and applied persistently in Phase 6.
DEVICE_IP=""
CONTROLLER_IP=""
PRIMARY_IF=""
RANDOM_MAC=""
NET_CONFIG_PENDING="false"
IFACE_CONF="/etc/network/interfaces.d/quantum-node"
SRC_MARKER="/etc/network/.quantum_managed_source_line"

# ---------------------------------------------------------------------------
# --- Phase 0: IP MANO / Network Configuration ---
# ---------------------------------------------------------------------------
# "Installed" means the MANO config file exists, NOT that we can ping 8.8.8.8.
# Reaching the internet via DHCP on a factory BBB is NOT a signal that the
# MANO configuration has been applied.
NET_INSTALLED=1
if [ -f "$IFACE_CONF" ]; then
    NET_INSTALLED=0
fi

if should_run_phase "Phase 0 (IP MANO / Network Configuration)" "$NET_INSTALLED"; then
    log_info "Preparing MANO network configuration..."

    # --- Detect primary network interface ---
    PRIMARY_IF=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    if [ -z "$PRIMARY_IF" ]; then
        PRIMARY_IF=$(ip -o link show 2>/dev/null | awk -F': ' \
            '$2 != "lo" && $2 !~ /^(docker|veth|br-)/ {print $2; exit}')
    fi

    if [ -z "$PRIMARY_IF" ]; then
        log_error "Could not auto-detect a primary network interface. Aborting Phase 0."
    else
        log_info "Primary network interface detected: $PRIMARY_IF"

        # --- Ask user for MANO IPs ---
        DEVICE_IP=$(prompt_with_default "Enter the IP address for THIS device (node)" "172.21.128.254")
        GATEWAY_IP=$(prompt_with_default "Enter the LAN gateway IP for the node subnet" "172.21.128.1")
        CONTROLLER_IP=$(prompt_with_default "Enter the IP address of the Network Controller" "172.21.2.23")
        log_info "Device IP: $DEVICE_IP   |   Gateway: $GATEWAY_IP   |   Controller: $CONTROLLER_IP"

        # --- Random, persistent, locally-administered unicast MAC ---
        RANDOM_MAC=""
        if [ -f "$IFACE_CONF" ]; then
            RANDOM_MAC=$(grep -i "hwaddress ether" "$IFACE_CONF" 2>/dev/null | awk '{print $3}')
        fi
        if [ -z "$RANDOM_MAC" ]; then
            # First octet 02 => locally administered + unicast (bit0=0, bit1=1)
            RANDOM_MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
                $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
                $((RANDOM % 256)) $((RANDOM % 256)))
            log_info "Generated new random MAC: $RANDOM_MAC"
        else
            log_info "Reusing existing persistent MAC from $IFACE_CONF: $RANDOM_MAC"
        fi

        NET_CONFIG_PENDING="true"

        # --- Session-only fallback so apt still works during this run ---
        if ! ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
            if ping -c 1 -W 1 10.0.0.1 > /dev/null 2>&1; then
                sudo ip route add default via 10.0.0.1 || true
                log_success "Temporary fallback default route via 10.0.0.1 added (session only)."
            else
                log_warn "Gateway 10.0.0.1 not reachable; will rely on existing link."
            fi

            if ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
                echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
                log_success "Temporary public DNS written to /etc/resolv.conf (session only)."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# --- Phase 0.5: System Time Synchronization ---
# ---------------------------------------------------------------------------
TIME_INSTALLED=1
if [ "$(date +%Y)" -ge 2024 ]; then
    TIME_INSTALLED=0
fi

if should_run_phase "Phase 0.5 (System Time Synchronization)" "$TIME_INSTALLED"; then
    log_info "Enabling systemd network time protocol (NTP)..."
    sudo timedatectl set-ntp true 2>/dev/null || true
    sudo systemctl restart systemd-timesyncd 2>/dev/null || true

    HTTP_DATE=$(curl -sI -m 5 http://google.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //g' | tr -d '\r')
    if [ -n "$HTTP_DATE" ]; then
        sudo date -s "$HTTP_DATE" >/dev/null
        log_success "Time synchronized successfully: $(date)"
    else
        log_warn "HTTP time sync failed. Relying on NTP daemon background sync."
    fi
fi

# ---------------------------------------------------------------------------
# --- Phase 0.7: PRE-EMPTIVE Deep System Cleanup (man pages preserved) ---
# ---------------------------------------------------------------------------
CLEANUP_INSTALLED=1
if [ -f /etc/dpkg/dpkg.cfg.d/01_nodoc ]; then
    CLEANUP_INSTALLED=0
fi

if should_run_phase "Phase 0.7 (Deep System Cleanup)" "$CLEANUP_INSTALLED"; then
    log_info "Purging unneeded packages and clearing cache (keeping man pages)..."
    sudo apt-get autoremove --purge -y || true
    sudo apt-get clean || true
    sudo journalctl --vacuum-time=1s 2>/dev/null || true
    sudo journalctl --vacuum-size=2M 2>/dev/null || true
    sudo find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete
    sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true

    # NOTE: /usr/share/man and /var/cache/man are intentionally NOT removed.
    sudo rm -rf /usr/share/doc/* /usr/share/info/* /usr/share/locale/*

    cat <<EOF | sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc >/dev/null
path-exclude /usr/share/doc/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
EOF
    sudo rm -rf /tmp/* /var/tmp/* ~/.cache/* /root/.cache/*
    # pip caches can grow to hundreds of MB on eMMC
    rm -rf ~/.cache/pip /root/.cache/pip 2>/dev/null || true
    log_success "Deep system cleanup complete (man pages preserved)."
fi

# ---------------------------------------------------------------------------
# --- Phase 0.8: SD Card Setup & Flasher Removal ---
# ---------------------------------------------------------------------------
if [ "$ARCH" = "aarch64" ]; then
    log_info "Phase 0.8: BB-AI64 detected. SD Card setup skipped."
else
    SD_INSTALLED=1
    if mountpoint -q /mnt/sdcard; then
        SD_INSTALLED=0
    fi

    if should_run_phase "Phase 0.8 (SD Card Offloading)" "$SD_INSTALLED"; then
        check_and_install parted util-linux e2fsprogs

        ROOT_MMC=$(findmnt -n -o SOURCE / | grep -o 'mmcblk[0-9]')
        if [ "$ROOT_MMC" = "mmcblk0" ]; then
            SD_DISK="/dev/mmcblk1"
        else
            SD_DISK="/dev/mmcblk0"
        fi

        if [ -b "$SD_DISK" ]; then
            log_info "Wiping all contents and eMMC flasher boot headers from $SD_DISK..."
            sudo systemctl stop quantum-grpc-agent quantum-netconf-agent quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true
            sudo umount /mnt/sdcard 2>/dev/null || true
            sudo umount -l ${SD_DISK}* 2>/dev/null || true

            # Delete entire partition table and zero out legacy U-Boot flasher sectors
            sudo dd if=/dev/zero of=$SD_DISK bs=1M count=10 status=none || true

            # Format clean ext4 partition
            sudo parted -s $SD_DISK mklabel msdos
            sudo parted -s $SD_DISK mkpart primary ext4 0% 100%
            sudo partprobe $SD_DISK
            sleep 2

            SD_TARGET="${SD_DISK}p1"
            sudo mkfs.ext4 -F $SD_TARGET

            sudo mkdir -p /mnt/sdcard
            sudo mount $SD_TARGET /mnt/sdcard

            # --- Resilient fstab entry ---
            # _netdev        : wait for device subsystem, not the network stack
            # nofail         : do not block boot if SD is absent
            # device-timeout : cap the wait so boot never hangs on the SD
            FSTAB_LINE="$SD_TARGET /mnt/sdcard auto defaults,nofail,_netdev,x-systemd.device-timeout=10 0 2"
            if ! grep -q "$SD_TARGET /mnt/sdcard" /etc/fstab; then
                echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
            else
                sudo sed -i "\|$SD_TARGET /mnt/sdcard|d" /etc/fstab
                echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
            fi

            sudo chown -R $USER:$USER /mnt/sdcard
            sudo mkdir -p /mnt/sdcard/apt-cache/partial
            sudo chown -R _apt:root /mnt/sdcard/apt-cache

            # Idempotent: only replace the local dir if it isn't already the
            # expected symlink.
            if [ ! -L /var/cache/apt/archives ] || \
               [ "$(readlink /var/cache/apt/archives)" != "/mnt/sdcard/apt-cache" ]; then
                sudo rm -rf /var/cache/apt/archives
                sudo ln -s /mnt/sdcard/apt-cache /var/cache/apt/archives
            fi
            log_success "SD Card wiped, formatted, mounted, and linked."
        else
            log_warn "No SD card hardware found at $SD_DISK."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# --- Phase 1: Base Tools & Package Setup ---
# ---------------------------------------------------------------------------
PKG_CHECK_LIST=(build-essential git curl wget jq systemd python3-pip parted util-linux tcpdump python3-ncclient python3-paramiko python3-lxml python3-cryptography)
PHASE1_INSTALLED=0
for p in "${PKG_CHECK_LIST[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed"; then
        PHASE1_INSTALLED=1
        break
    fi
done

FORCE_REINSTALL_PKGS="false"
if should_run_phase "Phase 1 (Base System Packages)" "$PHASE1_INSTALLED"; then
    [ "$PHASE1_INSTALLED" -eq 0 ] && FORCE_REINSTALL_PKGS="true"
    sudo rm -rf /var/lib/apt/lists/*
    sudo apt-get update -y || log_warn "APT update warning..."

    if [ "$ARCH" = "aarch64" ]; then
        check_and_install build-essential git curl wget jq systemd python3-pip python3-dev parted util-linux tcpdump
    else
        check_and_install build-essential git curl wget jq systemd python3-pip parted util-linux tcpdump
        sudo apt-get install -y --allow-downgrades \
          python3.7=3.7.3-2+deb10u3 \
          python3.7-minimal=3.7.3-2+deb10u3 \
          libpython3.7-stdlib=3.7.3-2+deb10u3 \
          libpython3.7-minimal=3.7.3-2+deb10u3 \
          libpython3.7=3.7.3-2+deb10u3 \
          python3.7-dev=3.7.3-2+deb10u3 \
          libpython3.7-dev=3.7.3-2+deb10u3 || log_warn "Python 3.7 downgrade step warning..."
    fi
    check_and_install python3-ncclient python3-paramiko python3-lxml python3-cryptography
fi

# ---------------------------------------------------------------------------
# --- Phase 2: Python Environment & gRPC ---
# ---------------------------------------------------------------------------
VENV_INSTALLED=1
if [ -f "venv/bin/python3" ] && ./venv/bin/python3 -c "import grpc" 2>/dev/null; then
    VENV_INSTALLED=0
fi

if should_run_phase "Phase 2 (Python Virtual Environment & gRPC)" "$VENV_INSTALLED"; then
    check_and_install golang-go protobuf-compiler
    sudo pip3 install --default-timeout=1000 --no-cache-dir virtualenv

    # The venv is what the agents need to run. Keep it on local eMMC so the
    # node stays functional even if the SD is absent or unmounted.
    rm -rf venv
    virtualenv --system-site-packages venv

    source venv/bin/activate
    pip install --upgrade pip

    if [ "$ARCH" != "aarch64" ]; then
        if ls ./builds/*.whl 1> /dev/null 2>&1; then
            pip install ./builds/*.whl
        else
            pip install --default-timeout=1000 --no-cache-dir --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf
        fi
    else
        pip install --default-timeout=1000 --no-cache-dir --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf
    fi
    deactivate
    log_success "Python environment created on local eMMC."
fi

# ---------------------------------------------------------------------------
# --- Phase 3: Hardware / GPIO Libraries ---
# ---------------------------------------------------------------------------
GPIO_INSTALLED=1
if dpkg-query -W -f='${Status}' "python3-libgpiod" 2>/dev/null | grep -q "ok installed"; then
    GPIO_INSTALLED=0
fi

if should_run_phase "Phase 3 (GPIO Libraries)" "$GPIO_INSTALLED"; then
    check_and_install gpiod libgpiod-dev python3-libgpiod
fi

# ---------------------------------------------------------------------------
# --- Phase 4: Project Structure & Protobuf compilation ---
# ---------------------------------------------------------------------------
PROTO_INSTALLED=1
if [ -f "proto/quantum_gnoi_switching_pb2.py" ]; then
    PROTO_INSTALLED=0
fi

if should_run_phase "Phase 4 (Directory Structure & Protobufs)" "$PROTO_INSTALLED"; then
    mkdir -p agent driver proto yang systemd test

    # Remove dead artifacts from earlier bootstrap runs.
    rm -f proto/quantum_gnmi_switching.proto \
          proto/quantum_gnmi_switching_pb2.py \
          proto/quantum_gnmi_switching_pb2_grpc.py
    rm -rf proto/github.com

    # ... logs, pin mappings symlinks unchanged ...

    # 1. gNOI proto definition
    cat <<EOF > proto/quantum_gnoi_switching.proto
syntax = "proto3";
package quantum.gnoi.switching.v1;
service QuantumGnoiSwitchingService {
  rpc SetCrossConnect (CrossConnectRequest) returns (CrossConnectResponse);
  rpc GetCrossConnectStatus (StatusRequest) returns (StatusResponse);
}
message CrossConnectRequest { bool state = 1; }
message CrossConnectResponse { bool success = 1; string message = 2; }
message StatusRequest {}
message StatusResponse { bool is_connected = 1; string switch_type = 2; }
EOF

    # Standard gNMI is used via the OpenConfig gnmi.proto below. There is no
    # custom gNMI proto; the earlier quantum_gnmi_switching.proto was dead
    # code (never imported by any agent) and has been removed.

    touch proto/__init__.py driver/__init__.py test/__init__.py agent/__init__.py

    ./venv/bin/python3 -m grpc_tools.protoc \
        -I. --python_out=. --grpc_python_out=. \
        proto/quantum_gnoi_switching.proto

    # Standard OpenConfig gNMI protos (pinned to v0.9.1).
    # ... same as before ...
    if [ ! -f "proto/gnmi.proto" ]; then
        curl -fsSL https://raw.githubusercontent.com/openconfig/gnmi/v0.9.1/proto/gnmi/gnmi.proto \
            -o proto/gnmi.proto
    fi
    if [ ! -f "proto/gnmi_ext.proto" ]; then
        curl -fsSL https://raw.githubusercontent.com/openconfig/gnmi/v0.9.1/proto/gnmi_ext/gnmi_ext.proto \
            -o proto/gnmi_ext.proto
    fi
    sed -i 's|import "github.com/openconfig/gnmi/proto/gnmi_ext/gnmi_ext.proto";|import "gnmi_ext.proto";|' proto/gnmi.proto
    ./venv/bin/python3 -m grpc_tools.protoc \
        -Iproto \
        --python_out=proto \
        --grpc_python_out=proto \
        proto/gnmi.proto \
        proto/gnmi_ext.proto

    touch proto/__init__.py
    log_success "Protobuf definitions compiled."
fi

# ---------------------------------------------------------------------------
# --- Phase 5: Systemd Setup ---
# ---------------------------------------------------------------------------
SVC_INSTALLED=1
if systemctl is-active --quiet quantum-grpc-agent && systemctl is-active --quiet quantum-netconf-agent 2>/dev/null; then
    SVC_INSTALLED=0
fi

if should_run_phase "Phase 5 (Systemd Services Setup)" "$SVC_INSTALLED"; then
    PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    # Design B: the venv is local, so the agents do not depend on the SD
    # mount. There is no wait-sdcard guard. Clean up any leftover unit from
    # a previous Design A install.
    if [ -f /etc/systemd/system/wait-sdcard.service ]; then
        sudo systemctl stop    wait-sdcard.service 2>/dev/null || true
        sudo systemctl disable wait-sdcard.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/wait-sdcard.service
    fi

    # 1. Unified gRPC (gNMI + gNOI) Service Unit
    cat <<EOF > "$PROJECT_DIR/systemd/quantum-grpc-agent.service"
[Unit]
Description=Quantum SDN Unified gNMI/gNOI Operations Agent
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/agent/gnoi_gnmi_agent.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 2. NETCONF Service Unit
    cat <<EOF > "$PROJECT_DIR/systemd/quantum-netconf-agent.service"
[Unit]
Description=Quantum SDN NETCONF Operations Agent
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/agent/netconf_agent.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl stop quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true
    sudo systemctl disable quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true
    sudo rm -f /etc/systemd/system/quantum-gnmi-agent.service /etc/systemd/system/quantum-gnoi-agent.service

    sudo cp "$PROJECT_DIR/systemd/quantum-grpc-agent.service" /etc/systemd/system/
    sudo cp "$PROJECT_DIR/systemd/quantum-netconf-agent.service" /etc/systemd/system/

    sudo systemctl daemon-reload
    sudo systemctl enable quantum-grpc-agent quantum-netconf-agent
    sudo systemctl restart quantum-grpc-agent quantum-netconf-agent
    log_success "Systemd services active."
fi

# ---------------------------------------------------------------------------
# --- Phase 6: Apply persistent MANO network configuration (IP/MAC/DNS) ---
# ---------------------------------------------------------------------------
if [ "$NET_CONFIG_PENDING" = "true" ] && [ -n "$PRIMARY_IF" ]; then
    log_info "Writing persistent network configuration to $IFACE_CONF..."

    sudo mkdir -p /etc/network/interfaces.d

    # Add source-directory line only if not already present. Marker file lets
    # the uninstaller know we were the one that added it.
    if ! grep -qE '^source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces 2>/dev/null; then
        echo "source-directory /etc/network/interfaces.d" | sudo tee -a /etc/network/interfaces > /dev/null
        sudo touch "$SRC_MARKER"
        log_info "Added source-directory line (marker $SRC_MARKER set for later cleanup)."
    fi

    sudo tee "$IFACE_CONF" > /dev/null <<EOF
# Quantum Node Switching - managed by bootstrap-node.sh
# Node: $DEVICE_IP   Gateway: $GATEWAY_IP   Controller: $CONTROLLER_IP
auto $PRIMARY_IF
iface $PRIMARY_IF inet static
    address $DEVICE_IP
    netmask 255.255.255.0
    gateway $GATEWAY_IP
    hwaddress ether $RANDOM_MAC
    dns-nameservers $CONTROLLER_IP 8.8.8.8 1.1.1.1
    # Controller lives on a different subnet; reach it via the LAN gateway.
    up   ip route add $CONTROLLER_IP/32 via $GATEWAY_IP || true
    down ip route del $CONTROLLER_IP/32 via $GATEWAY_IP || true
EOF
    log_success "Persistent interface config written."

    # Update the on-disk resolv.conf: Controller first, public resolvers as fallback
    sudo rm -f /etc/resolv.conf
    sudo tee /etc/resolv.conf > /dev/null <<EOF
# Managed by bootstrap-node.sh
nameserver $CONTROLLER_IP
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:1 attempts:1
EOF
    log_success "Persistent /etc/resolv.conf written (controller + public fallback)."

    # No iptables rules are required; the static default route via the
    # controller handles northbound traffic.
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To tail live gRPC agent logs:    ${YELLOW}journalctl -u quantum-grpc-agent -f${NC}"
echo -e "To tail live NETCONF agent logs: ${YELLOW}journalctl -u quantum-netconf-agent -f${NC}"
echo -e "To tail all live logs together:  ${YELLOW}journalctl -u quantum-grpc-agent -u quantum-netconf-agent -f${NC}"
echo -e "${GREEN}====================================================${NC}"

# ---------------------------------------------------------------------------
# --- Final step: reboot to apply IP/MAC/network changes ---
# ---------------------------------------------------------------------------
log_info "Flushing filesystem buffers and rebooting to apply network config..."
sync
sleep 3
log_warn "If this is a remote SSH session, it will now disconnect."
sleep 2
sudo reboot -f
