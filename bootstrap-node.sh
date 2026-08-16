#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Universal Bootstrap Script
# (Features: Auto-detects BBB vs BB-AI64, Smart APT, SD Expansion, Virtual RAM)
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

# Detect Architecture
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

# --- Phase 1: System Updates & Architecture-Specific Fixes ---
if prompt_yes_no "Phase 1: Update system and install base dependencies?"; then
    log_info "Updating APT package lists..."
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

# --- Phase 1.5: System Cleanup ---
if prompt_yes_no "Phase 1.5: Run system cleanup to free up eMMC storage?"; then
    log_info "Removing orphaned/unnecessary APT packages..."
    sudo apt-get autoremove -y
    sudo apt-get clean
    log_info "Clearing local PIP caches..."
    rm -rf ~/.cache/pip
    sudo rm -rf /root/.cache/pip
    log_success "System cleanup complete. Storage freed."
fi

# --- Phase 1.8: SD Card Expansion & Auto-Format ---
if [ "$ARCH" = "aarch64" ]; then
    log_info "Phase 1.8: BB-AI64 detected. SD Card setup is not required. Skipping..."
else
    log_info "Phase 1.8: BBB detected. An SD card is REQUIRED for logs and compilation space."
    
    if prompt_yes_no "Proceed with detecting, formatting, and mounting the SD card?"; then
        SD_DISK="/dev/mmcblk0"
        SD_PART="/dev/mmcblk0p1"
        
        # Pause and wait for the user to insert the SD card if it's not already there
        while [ ! -b "$SD_DISK" ]; do
            echo -e "${RED}WARNING: No SD card detected at $SD_DISK.${NC}"
            read -p "Please insert an SD card into the BBB and press Enter to scan again (or type 'skip' to bypass)... " sd_input
            if [ "$sd_input" = "skip" ]; then
                log_warn "Skipping SD card setup. Warning: Compilation may fail due to lack of space!"
                break
            fi
            sleep 2 # Give the OS time to register the block device
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
        fi
    else
        log_warn "Skipping Phase 1.8. Note: Building heavy python packages on the BBB without an SD card may crash."
    fi
fi

# --- Phase 2: Hardware / GPIO Libraries ---
if prompt_yes_no "Phase 2: - notice: other faster gpio methods could be used - Install GPIO control libraries (libgpiod)?"; then
    log_info "Scanning and installing libgpiod..."
    check_and_install gpiod libgpiod-dev python3-libgpiod
fi

# --- Phase 3: gRPC, Protobuf, and VirtualEnv ---
if prompt_yes_no "Phase 3: Install gRPC, Protobuf, and Python environment?"; then
    log_info "Scanning and installing C++ dependencies..."
    check_and_install golang-go protobuf-compiler

    log_info "Ensuring virtualenv is installed via pip..."
    sudo pip3 install --default-timeout=1000 --no-cache-dir virtualenv

    log_info "Setting up Python virtual environment (./venv)..."
    rm -rf venv
    virtualenv --system-site-packages venv
    source venv/bin/activate
    pip install --default-timeout=1000 --upgrade pip
    
    if mountpoint -q /mnt/sdcard; then
        log_success "SD Card found! Routing pip build files to /mnt/sdcard/pip_build_tmp..."
        mkdir -p /mnt/sdcard/pip_build_tmp
        export TMPDIR=/mnt/sdcard/pip_build_tmp
        
        # Only provision swap on the 32-bit BBB (it has 512MB RAM). AI-64 has plenty.
        if [ "$ARCH" != "aarch64" ]; then
            log_info "BBB detected. Creating 2GB temporary Swap file on SD Card to prevent memory exhaustion..."
            sudo fallocate -l 2G /mnt/sdcard/temp_swap
            sudo chmod 600 /mnt/sdcard/temp_swap
            sudo mkswap /mnt/sdcard/temp_swap
            sudo swapon /mnt/sdcard/temp_swap
            log_success "2GB Swap file activated."
        fi
    else
        log_warn "No SD Card found. Using root for pip build files."
        mkdir -p $(pwd)/pip_build_tmp
        export TMPDIR=$(pwd)/pip_build_tmp
    fi
    
    log_info "Installing gRPC tools..."
    echo -e "${YELLOW}[NOTE] Compiling from source to match local GLIBC. This can take up to 60 mins.${NC}"
    
    # --- GRPCIO INSTALLATION LOGIC ---
    if [ "$ARCH" != "aarch64" ]; then
        log_info "BBB detected: Applying strict memory limits and compiling from source..."
        
        # 1. Force single-threaded compilation (BBB is single-core, >1 just wastes RAM)
        export GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=1
        
        # 2. -g0 strips debug symbols (CRITICAL to prevent 'Out of Disk Space' crashes)
        export CFLAGS="-g0"
        export CXXFLAGS="-g0"
        
        # Install forcing source build for BBB architecture
        pip install --default-timeout=1000 --no-cache-dir --no-binary=grpcio,grpcio-tools --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf

        # Unset the flags so they don't affect future commands
        unset GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS CFLAGS CXXFLAGS
    else
        log_info "BB-AI64 (aarch64) detected: Using pre-compiled binary wheels..."
        
        # Standard install allowing pre-compiled binaries (bypasses the disk space crash)
        pip install --default-timeout=1000 --no-cache-dir --extra-index-url https://www.piwheels.org/simple grpcio grpcio-tools protobuf
    fi
        
    # Cleanup build environment and turn off swap
    if [ -n "$TMPDIR" ]; then rm -rf "$TMPDIR"; fi
    unset TMPDIR
    
    if mountpoint -q /mnt/sdcard && [ -f /mnt/sdcard/temp_swap ]; then
        log_info "Deactivating and removing 2GB temporary swap file..."
        sudo swapoff /mnt/sdcard/temp_swap
        sudo rm /mnt/sdcard/temp_swap
    fi
    
    deactivate
    log_success "gRPC and Python environment ready."
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
After=network.target

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
    log_success "Systemd service configured."
fi

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Bootstrap Execution Complete! ${NC}"
echo -e "To tail live agent logs: ${YELLOW}tail -f logs/agent.log${NC}"
echo -e "${GREEN}====================================================${NC}"
