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

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

prompt_yes_no() {
    while true; do
        echo -e -n "$1 [y/N]: "
        read yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Auto-installs missing items silently; prompts user only if already installed.
should_run_phase() {
    local phase_name="$1"
    local is_installed="$2" # 0 = installed/configured, 1 = missing/not configured

    if [ "$is_installed" -eq 1 ]; then
        log_info "$phase_name is missing/unconfigured. Auto-installing..."
        return 0
    else
        log_warn "$phase_name is already installed and active."
        if prompt_yes_no "Do you want to re-install / re-configure $phase_name?"; then
            return 0
        else
            log_info "Skipping $phase_name."
            return 1
        fi
    fi
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

    # If missing packages exist, install them automatically
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log_info "Auto-installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --fix-missing "${missing_pkgs[@]}" || log_warn "Some packages failed to install, attempting to proceed..."
    fi

    # If user specifically confirmed reinstalling already-present packages
    if [ ${#installed_pkgs[@]} -ne 0 ] && [ "$FORCE_REINSTALL_PKGS" = "true" ]; then
        log_info "Re-installing requested packages: ${installed_pkgs[*]}"
        sudo apt-get install -y --reinstall "${installed_pkgs[@]}" || true
    fi
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup ===${NC}"

ARCH=$(uname -m)
log_info "Detected System Architecture: $ARCH"

# --- Phase 0: Network Configuration ---
NET_INSTALLED=1
if ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
    NET_INSTALLED=0
fi

if should_run_phase "Phase 0 (Network Connectivity)" "$NET_INSTALLED"; then
    log_info "Configuring network interfaces and DNS..."
    if ! ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
        if ping -c 1 -W 1 10.0.0.1 > /dev/null 2>&1; then
            sudo ip route add default via 10.0.0.1 || true
            log_success "Fallback default route via 10.0.0.1 added."
        else
            log_error "Gateway 10.0.0.1 not reachable. Network connectivity may fail."
        fi
    fi

    if ! grep -q "8.8.8.8" /etc/resolv.conf; then
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
        log_success "Resolv.conf updated with public DNS."
    fi
fi

# --- Phase 0.5: System Time Synchronization ---
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

# --- Phase 0.7: PRE-EMPTIVE Deep System Cleanup ---
CLEANUP_INSTALLED=1
if [ -f /etc/dpkg/dpkg.cfg.d/01_nodoc ]; then
    CLEANUP_INSTALLED=0
fi

if should_run_phase "Phase 0.7 (Deep System Cleanup)" "$CLEANUP_INSTALLED"; then
    log_info "Purging unneeded packages and clearing cache..."
    sudo apt-get autoremove --purge -y || true
    sudo apt-get clean || true
    sudo journalctl --vacuum-time=1s 2>/dev/null || true
    sudo journalctl --vacuum-size=2M 2>/dev/null || true
    sudo find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete
    sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true

    sudo rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/* /var/cache/man/*

    cat <<EOF | sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc >/dev/null
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
EOF
    sudo rm -rf /tmp/* /var/tmp/* ~/.cache/* /root/.cache/*
    log_success "Deep system cleanup complete."
fi

# --- Phase 0.8: SD Card Setup & Flasher Removal ---
if [ "$ARCH" = "aarch64" ]; then
    log_info "Phase 0.8: BB-AI64 detected. SD Card setup skipped."
else
    SD_INSTALLED=1
    if mountpoint -q /mnt/sdcard; then
        SD_INSTALLED=0
    fi

    if should_run_phase "Phase 0.8 (SD Card Offloading)" "$SD_INSTALLED"; then
        # Ensure required partition tools exist before proceeding
        check_and_install parted util-linux e2fsprogs

        ROOT_MMC=$(findmnt -n -o SOURCE / | grep -o 'mmcblk[0-9]')
        if [ "$ROOT_MMC" = "mmcblk0" ]; then
            SD_DISK="/dev/mmcblk1"
        else
            SD_DISK="/dev/mmcblk0"
        fi

        if [ -b "$SD_DISK" ]; then
            log_info "Wiping all contents and eMMC flasher boot headers from $SD_DISK..."
            sudo systemctl stop quantum-gnoi-agent quantum-netconf-agent 2>/dev/null || true
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
            if ! grep -q "$SD_TARGET /mnt/sdcard" /etc/fstab; then
                echo "$SD_TARGET /mnt/sdcard auto defaults,nofail 0 2" | sudo tee -a /etc/fstab
            fi

            sudo chown -R $USER:$USER /mnt/sdcard
            sudo mkdir -p /mnt/sdcard/apt-cache/partial
            sudo chown -R _apt:root /mnt/sdcard/apt-cache
            sudo rm -rf /var/cache/apt/archives
            sudo ln -s /mnt/sdcard/apt-cache /var/cache/apt/archives
            log_success "SD Card wiped, formatted, mounted, and linked."
        else
            log_warn "No SD card hardware found at $SD_DISK."
        fi
    fi
fi

# --- Phase 1: Base Tools & Package Setup ---
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

# --- Phase 2: Python Environment & gRPC ---
VENV_INSTALLED=1
if [ -f "venv/bin/python3" ] && ./venv/bin/python3 -c "import grpc" 2>/dev/null; then
    VENV_INSTALLED=0
fi

if should_run_phase "Phase 2 (Python Virtual Environment & gRPC)" "$VENV_INSTALLED"; then
    check_and_install golang-go protobuf-compiler
    sudo pip3 install --default-timeout=1000 --no-cache-dir virtualenv
    rm -rf venv

    if mountpoint -q /mnt/sdcard; then
        mkdir -p /mnt/sdcard/venv
        sudo chown -R $USER:$USER /mnt/sdcard/venv
        virtualenv --system-site-packages /mnt/sdcard/venv
        ln -sfn /mnt/sdcard/venv venv
    else
        virtualenv --system-site-packages venv
    fi

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
    log_success "Python environment successfully created."
fi

# --- Phase 3: Hardware / GPIO Libraries ---
GPIO_INSTALLED=1
if dpkg-query -W -f='${Status}' "python3-libgpiod" 2>/dev/null | grep -q "ok installed"; then
    GPIO_INSTALLED=0
fi

if should_run_phase "Phase 3 (GPIO Libraries)" "$GPIO_INSTALLED"; then
    check_and_install gpiod libgpiod-dev python3-libgpiod
fi

# --- Phase 4: Project Structure & Protobuf compilation ---
PROTO_INSTALLED=1
if [ -f "proto/quantum_gnoi_switching_pb2.py" ]; then
    PROTO_INSTALLED=0
fi

if should_run_phase "Phase 4 (Directory Structure & Protobufs)" "$PROTO_INSTALLED"; then
    mkdir -p agent driver proto yang systemd test

    if mountpoint -q /mnt/sdcard; then
        mkdir -p /mnt/sdcard/quantum_logs
        rm -rf logs
        ln -sfn /mnt/sdcard/quantum_logs logs
    else
        [ -L logs ] && rm -f logs
        mkdir -p logs
    fi

    rm -f driver/gnoi_pin_mappings.json driver/netconf_pin_mappings.json driver/pin_mappings.json
    if [ "$ARCH" = "aarch64" ]; then
        ln -sfn pin_switching_mappings.ai64.json driver/gnoi_pin_mappings.json
        ln -sfn pin_switching_mappings.ai64.json driver/netconf_pin_mappings.json
    else
        ln -sfn pin_switching_mappings.bbb.json driver/gnoi_pin_mappings.json
        ln -sfn pin_switching_mappings.bbb.json driver/netconf_pin_mappings.json
    fi

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

    touch proto/__init__.py driver/__init__.py test/__init__.py agent/__init__.py
    ./venv/bin/python3 -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. proto/quantum_gnoi_switching.proto
    log_success "Protobuf definitions compiled."
fi

# --- Phase 5: Systemd Setup ---
SVC_INSTALLED=1
if systemctl is-active --quiet quantum-gnoi-agent 2>/dev/null; then
    SVC_INSTALLED=0
fi

if should_run_phase "Phase 5 (Systemd Services Setup)" "$SVC_INSTALLED"; then
    PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    REQUIRES_SD=""
    if mountpoint -q /mnt/sdcard; then
        REQUIRES_SD="RequiresMountsFor=/mnt/sdcard"
    fi

    cat <<EOF > "$PROJECT_DIR/systemd/quantum-gnoi-agent.service"
[Unit]
Description=Quantum SDN gNOI Operations Agent
After=network.target local-fs.target
$REQUIRES_SD

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/agent/gnoi_agent.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$PROJECT_DIR/logs/agent.log
StandardError=append:$PROJECT_DIR/logs/agent.log

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > "$PROJECT_DIR/systemd/quantum-netconf-agent.service"
[Unit]
Description=Quantum SDN NETCONF Operations Agent
After=network.target local-fs.target
$REQUIRES_SD

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python3 $PROJECT_DIR/agent/netconf_agent.py
Restart=on-failure
RestartSec=5
StandardOutput=append:$PROJECT_DIR/logs/netconf_agent.log
StandardError=append:$PROJECT_DIR/logs/netconf_agent.log

[Install]
WantedBy=multi-user.target
EOF

    sudo rm -f /etc/systemd/system/quantum-gnoi-agent.service /etc/systemd/system/quantum-netconf-agent.service
    sudo cp "$PROJECT_DIR/systemd/quantum-gnoi-agent.service" /etc/systemd/system/
    sudo cp "$PROJECT_DIR/systemd/quantum-netconf-agent.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable quantum-gnoi-agent quantum-netconf-agent
    sudo systemctl restart quantum-gnoi-agent quantum-netconf-agent
    log_success "Systemd services active."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To tail live agent logs: ${YELLOW}tail -f logs/agent.log${NC}"
echo -e "${GREEN}====================================================${NC}"
