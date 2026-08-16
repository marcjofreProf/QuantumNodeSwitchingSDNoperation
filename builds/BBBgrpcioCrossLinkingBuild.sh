#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum Node Switching - Host Cross-Compilation Script (BBB arm32v7)
# Runs on Host Machine (Linux/macOS) with Docker
# Builds and cross-links for BBB the tools grpcio, grpcio-tools and protobuf
# ---------------------------------------------------------------------------
# Just required to be built once
# Requires docker
# sudo apt-get update
# sudo apt-get install -y docker.io
# Add Your User to the Docker Group. The script runs docker commands without sudo. To allow your user  to do this, add yourself to the docker group:
# sudo usermod -aG docker $USER
# Start the Docker Service
# sudo service docker start
# ----------------------------------------------------------------------------
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

echo -e "${YELLOW}=== BBB gRPC Arm32v7 Cross-Wheel Builder ===${NC}"

# 1. Verify Docker installation
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH. Please install Docker to use cross-compilation."
    exit 1
fi

# 2. Ensure target builds directory is the directory the script resides in
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR"
log_info "Output directory ready at: $BUILD_DIR"

# 3. Register QEMU for ARM emulation
log_info "Registering QEMU multi-architecture emulators..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null 2>&1 || true

# 4. Build wheels inside 32-bit Debian Buster container matching BBB OS
log_info "Launching 32-bit ARM Debian Buster container to compile wheels..."
log_warn "This process takes roughly 10-20 minutes on a desktop CPU instead of 12 hours on BBB."

docker run --rm \
    -v "$BUILD_DIR:/output" \
    arm32v7/debian:buster bash -c "
        set -e
        
        echo '[CONTAINER] Fixing Debian Buster APT sources (OS reached End-of-Life)...'
        echo 'deb http://archive.debian.org/debian buster main' > /etc/apt/sources.list
        echo 'deb http://archive.debian.org/debian-security buster/updates main' >> /etc/apt/sources.list
        echo 'Acquire::Check-Valid-Until \"false\";' > /etc/apt/apt.conf.d/10no-check-valid-until

        echo '[CONTAINER] Updating package manager...'
        apt-get update -y
        
        echo '[CONTAINER] Downgrading and fixing Python 3.7 dev libraries...'
        apt-get install -y --allow-downgrades \
            python3.7=3.7.3-2+deb10u3 \
            python3.7-minimal=3.7.3-2+deb10u3 \
            libpython3.7-stdlib=3.7.3-2+deb10u3 \
            libpython3.7-minimal=3.7.3-2+deb10u3 \
            libpython3.7=3.7.3-2+deb10u3 \
            python3.7-dev=3.7.3-2+deb10u3 \
            libpython3.7-dev=3.7.3-2+deb10u3 \
            python3-pip build-essential git
        
        echo '[CONTAINER] Upgrading build tools...'
        python3.7 -m pip install --upgrade pip setuptools wheel

        echo '[CONTAINER] Compiling grpcio, grpcio-tools, and protobuf wheels...'
        python3.7 -m pip wheel --no-cache-dir grpcio grpcio-tools protobuf -w /output
        
        echo '[CONTAINER] Setting ownership of built files...'
        chmod 666 /output/*.whl
    "

log_success "Cross-compilation complete!"
log_info "The compiled wheels are ready in $BUILD_DIR to be committed to GitHub:"
ls -lh "$BUILD_DIR"/*.whl
