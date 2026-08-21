#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Universal Bootstrap Script
# (Features: Auto-detects BBB vs BB-AI64, Local Wheel Install, Log SD Offload)
# ---------------------------------------------------------------------------

set -e

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
        echo -e -n "$1 [y/N]; "
	read yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

check_and_install() {
    local missing_pkgs=()
    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            echo -e "  -> [SKIP] $pkg is already installed."
        else
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        log_info "Installing missing packages: ${missing_pkgs[*]}"
        sudo apt-get install -y "${missing_pkgs[@]}"
    else
        log_success "All requested packages are already present!"
    fi
}

echo -e "${YELLOW}=== Quantum Node Switching Agent Setup ===${NC}"

ARCH=$(uname -m)
log_info "Detected System Architecture: $ARCH"

# --- Phase 0: Network Configuration ---
if prompt_yes_no "Phase 0: Verify internet connectivity (Prioritize MANO; Fallback to 10.0.0.1)?"; then
    log_info "Checking if priority path is already operative..."
    if ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log_success "External connectivity verified."
    else
        log_warn "Ping check failed. Attempting fallback to 10.0.0.1..."
        if ping -c 1 -W 1 10.0.0.1 > /dev/null 2>&1; then
            sudo ip route add default via 10.0.0.1 || true
            log_success "Fallback default route via 10.0.0.1 added."
        else
            log_error "Gateway 10.0.0.1 not reachable. You may lack internet."
        fi
    fi

    if ! grep -q "8.8.8.8" /etc/resolv.conf; then
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
        log_success "Resolv.conf updated with public DNS."
    fi
fi

# --- Phase 0.5: System Time Synchronization ---
if prompt_yes_no "Phase 0.5: Synchronize system time (fixes SSL and APT certificate errors)?"; then
    log_info "Enabling systemd network time protocol (NTP)..."
    sudo timedatectl set-ntp true 2>/dev/null || true
    sudo systemctl restart systemd-timesyncd 2>/dev/null || true
    
    log_info "Attempting HTTP time sync fallback (bypasses SSL errors on old clocks)..."
    HTTP_DATE=$(curl -sI -m 5 http://google.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //g' | tr -d '\r')
    
    if [ -n "$HTTP_DATE" ]; then
        sudo date -s "$HTTP_DATE" >/dev/null
        log_success "Time synchronized successfully: $(date)"
    else
        log_warn "HTTP time sync failed. Relying on NTP daemon background sync."
    fi
fi

# --- Phase 0.7: PRE-EMPTIVE Deep System Cleanup ---
if prompt_yes_no "Phase 0.7: Run pre-emptive deep cleanup to free up eMMC storage before downloads?"; then
    log_info "Purging unneeded packages and cleaning APT cache..."
    sudo apt-get autoremove --purge -y
    sudo apt-get clean

    log_info "Vacuuming systemd journal logs to absolute minimum..."
    sudo journalctl --vacuum-time=1s 2>/dev/null || true
    sudo journalctl --vacuum-size=2M 2>/dev/null || true

    log_info "Clearing rotated log archives in /var/log..."
    sudo find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete
    
    log_info "Truncating active text logs safely..."
    sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true

    # --- NEW: Deep OS Documentation and Locale Wipe (~150MB+ saved) ---
    log_info "Wiping system documentation, manual pages, and unused language locales..."
    sudo rm -rf /usr/share/doc/*
    sudo rm -rf /usr/share/man/*
    sudo rm -rf /usr/share/info/*
    sudo rm -rf /usr/share/locale/*
    sudo rm -rf /var/cache/man/*

    log_info "Configuring dpkg to permanently drop docs and locales on future installs..."
    if [ ! -f /etc/dpkg/dpkg.cfg.d/01_nodoc ]; then
        cat <<EOF | sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc >/dev/null
        path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
EOF

        log_success "dpkg nodoc configuration created."
    else
        log_info "dpkg nodoc configuration already exists. Skipping creation."
    fi
    
    log_info "Clearing temporary files and user caches..."
    sudo rm -rf /tmp/* /var/tmp/*
    rm -rf ~/.cache/*
    sudo rm -rf /root/.cache/*
    
    log_success "Deep system cleanup complete. Maximum eMMC storage freed."
fi

# --- Phase 0.8: PRE-EMPTIVE SD Card Setup for Logging & APT Cache ---
if [ "$ARCH" = "aarch64" ]; then
    log_info "Phase 0.8: BB-AI64 detected. SD Card setup is not required. Skipping..."
else
    log_info "Phase 0.8: BBB detected. Routing APT Cache and logs to SD card to preserve eMMC..."
    
    if prompt_yes_no "Proceed with detecting, formatting, and mounting the SD card?"; then
	# Find which drive hosts the active OS root filesystem
	ROOT_MMC=$(findmnt -n -o SOURCE / | grep -o 'mmcblk[0-9]')
	
	# Dynamically target the other MMC device for the SD card
	if [ "$ROOT_MMC" = "mmcblk0" ]; then
	    SD_DISK="/dev/mmcblk1"
	    SD_PART="/dev/mmcblk1p1"
	else
	    SD_DISK="/dev/mmcblk0"
	    SD_PART="/dev/mmcblk0p1"
	fi

        while [ ! -b "$SD_DISK" ]; do
            echo -e "${RED}WARNING: No SD card detected at $SD_DISK.${NC}"
            read -p "Please insert an SD card into the BBB and press Enter to scan again (or type 'skip' to bypass)... " sd_input
            if [ "$sd_input" = "skip" ]; then
                log_warn "Skipping SD card setup. Warning: Installs and logs will write directly to internal eMMC flash storage."
                break
            fi
            sleep 2
        done
        
        if [ -b "$SD_DISK" ]; then
            log_info "Detected SD Card hardware at $SD_DISK."
            
            if ! sudo blkid $SD_PART | grep -q "ext4"; then
                log_warn "SD Card is NOT formatted as ext4 or partition is missing."
                if prompt_yes_no "${RED}WARNING: Do you want to format $SD_DISK to ext4? This will ERASE ALL DATA on the SD card!${NC}"; then
                    log_info "Formatting $SD_DISK to ext4..."
                    sudo umount $SD_PART 2>/dev/null || true
                    sudo parted -s $SD_DISK mklabel msdos
                    sudo parted -s $SD_DISK mkpart primary ext4 0% 100%
                    sudo partprobe $SD_DISK
                    sleep 2
                    sudo mkfs.ext4 -F $SD_PART
                    log_success "SD Card successfully formatted."
                else
                    log_warn "Skipping format."
                fi
            else
                log_success "SD Card partition $SD_PART is properly formatted as ext4."
            fi

            sudo mkdir -p /mnt/sdcard
            if ! mountpoint -q /mnt/sdcard; then
                log_info "Mounting SD card to /mnt/sdcard..."
                sudo mount $SD_PART /mnt/sdcard || log_error "Failed to mount $SD_PART."
                if ! grep -q "$SD_PART /mnt/sdcard" /etc/fstab; then
                    echo "$SD_PART /mnt/sdcard auto defaults,nofail 0 2" | sudo tee -a /etc/fstab
                    log_success "Added SD card to /etc/fstab."
                fi
            else
                log_success "SD card is already mounted at /mnt/sdcard."
            fi
            
            log_info "Setting permissions for user $USER on SD card..."
            sudo chown -R $USER:$USER /mnt/sdcard

            # --- Offload APT Cache immediately before Phase 1 ---
            log_info "Offloading APT package cache to SD card to save eMMC space..."
            sudo mkdir -p /mnt/sdcard/apt-cache/partial
            sudo chown -R _apt:root /mnt/sdcard/apt-cache
            sudo rm -rf /var/cache/apt/archives
            sudo ln -s /mnt/sdcard/apt-cache /var/cache/apt/archives
            log_success "APT cache successfully linked to SD card."
        fi
    else
        log_warn "Skipping Phase 0.8. Everything will be kept on the internal eMMC."
    fi
fi

# --- Phase 1: System Updates & Architecture-Specific Fixes ---
if prompt_yes_no "Phase 1: Update system and install base dependencies?"; then
    log_info "Updating APT package lists..."
    sudo rm -rf /var/lib/apt/lists/*
    sudo apt-get update -y
    
    if [ "$ARCH" = "aarch64" ]; then
        log_info "64-bit architecture (BB-AI64) detected. Installing standard Python 3 packages..."
        check_and_install build-essential git curl wget jq systemd python3-pip python3-dev parted util-linux
    else
        log_info "32-bit architecture (BBB) detected. Installing base tools..."
        check_and_install build-essential git curl wget jq systemd python3-pip parted util-linux
        
        log_warn "Applying Debian Buster downgrade fix for BBB python3-dev..."
        sudo apt-get install -y --allow-downgrades \
          python3.7=3.7.3-2+deb10u3 \
          python3.7-minimal=3.7.3-2+deb10u3 \
          libpython3.7-stdlib=3.7.3-2+deb10u3 \
          libpython3.7-minimal=3.7.3-2+deb10u3 \
          libpython3.7=3.7.3-2+deb10u3 \
          python3.7-dev=3.7.3-2+deb10u3 \
          libpython3.7-dev=3.7.3-2+deb10u3
    fi
fi

# --- Phase 2: gRPC, Protobuf, and VirtualEnv ---
if prompt_yes_no "Phase 2: Install gRPC, Protobuf, and Python environment?"; then
    log_info "Scanning and installing C++ dependencies..."
    check_and_install golang-go protobuf-compiler

    log_info "Ensuring virtualenv is installed via pip..."
    sudo pip3 install --default-timeout=1000 --no-cache-dir virtualenv

    log_info "Setting up Python virtual environment (./venv)..."
    rm -rf venv
    
    if mountpoint -q /mnt/sdcard; then
        log_info "SD Card detected! Offloading Python virtual environment to /mnt/sdcard/venv..."
        mkdir -p /mnt/sdcard/venv
        sudo chown -R $USER:$USER /mnt/sdcard/venv
        virtualenv --system-site-packages /mnt/sdcard/venv
        ln -sfn /mnt/sdcard/venv venv
        log_success "Virtual environment successfully linked to SD card."
    else
        log_warn "No SD card mounted. Creating virtual environment locally on eMMC..."
        virtualenv --system-site-packages venv
    fi

    source venv/bin/activate
    pip install --upgrade pip

    if [ "$ARCH" != "aarch64" ]; then
        log_info "BBB detected. Checking for local pre-compiled wheels in ./builds..."
        if ls ./builds/*.whl 1> /dev/null 2>&1; then
            log_success "Found local pre-compiled wheels in ./builds! Installing directly..."
            pip install ./builds/*.whl
        else
            log_warn "No local pre-compiled wheels found. Falling back to remote PiWheels..."
            pip install --default-timeout=1000 --no-cache-dir --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf
        fi
    else
        log_info "BB-AI64 (aarch64) detected: Using standard binary wheels..."
        pip install --default-timeout=1000 --no-cache-dir --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf
    fi
    
    deactivate
    log_success "gRPC and Python environment ready."
fi

# --- Phase 3: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 3: Install GPIO control libraries (libgpiod)?"; then
    log_info "Scanning and installing libgpiod..."
    check_and_install gpiod libgpiod-dev python3-libgpiod
fi

# --- Phase 4: Scaffold Repository Structure & Compile Protobufs ---
if prompt_yes_no "Phase 4: Generate directory structure, configs, and Protobufs?"; then
    log_info "Creating node-level folder structure..."
    mkdir -p agent driver proto systemd test
    
    if mountpoint -q /mnt/sdcard; then
        log_success "SD Card found! Symlinking agent logs to /mnt/sdcard/quantum_logs..."
        mkdir -p /mnt/sdcard/quantum_logs
        rm -rf logs
        ln -sfn /mnt/sdcard/quantum_logs logs
    else
        [ -L logs ] && rm -f logs
        mkdir -p logs
    fi

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

    log_info "Generating gNOI Protobuf definition (proto/quantum_switch.proto)..."
    cat <<EOF > proto/quantum_switch.proto
syntax = "proto3";

package quantum.switch.v1;

service QuantumSwitchService {
  rpc SetCrossConnect (CrossConnectRequest) returns (CrossConnectResponse);
  rpc GetCrossConnectStatus (StatusRequest) returns (StatusResponse);
}

message CrossConnectRequest {
  bool state = 1; // true = CONNECTED, false = DISCONNECTED
}

message CrossConnectResponse {
  bool success = 1;
  string message = 2;
}

message StatusRequest {}

message StatusResponse {
  bool is_connected = 1;
  string switch_type = 2;
}
EOF

    log_info "Compiling gRPC Python stubs..."
    touch proto/__init__.py
    ./venv/bin/python3 -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. proto/quantum_switch.proto
    
    log_success "Directories, configurations, and Protobufs successfully created."
fi

# --- Phase 5: Systemd Service Scaffold ---
if prompt_yes_no "Phase 5: Generate and install systemd service (quantum-gnoi-agent)?"; then
    log_info "Generating Systemd Configuration..."
    cat <<EOF > systemd/quantum-gnoi-agent.service
[Unit]
Description=Quantum SDN gNOI Operations Agent
After=network.target local-fs.target
RequiresMountsFor=/mnt/sdcard

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python3 $(pwd)/agent/gnoi_agent.py
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
    
    log_info "Enabling and starting the quantum-gnoi-agent service..."
    sudo systemctl enable quantum-gnoi-agent
    sudo systemctl start quantum-gnoi-agent
    
    log_success "Systemd service configured, enabled on boot, and currently running."    
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To tail live agent logs: ${YELLOW}tail -f logs/agent.log${NC}"
echo -e "${GREEN}====================================================${NC}"
