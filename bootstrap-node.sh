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

# ---------------------------------------------------------------------------
# Ensure /var/cache/apt/archives is usable before any apt operation.
#
# A previous bootstrap run may have left /var/cache/apt/archives as a
# symlink to /mnt/sdcard/apt-cache. If the SD card is not mounted at
# this moment, the symlink is dangling and every apt command fails with:
#   E: Archives directory /var/cache/apt/archives/partial is missing.
#
# Restore the local eMMC directory in that case. Phase 0.8 will
# re-create the SD symlink later if the SD is present and mounted.
# ---------------------------------------------------------------------------
if [ -L /var/cache/apt/archives ] && [ ! -d /var/cache/apt/archives ]; then
    log_warn "APT cache symlink is dangling (SD not mounted); restoring local cache."
    sudo rm -f /var/cache/apt/archives
fi

if [ ! -d /var/cache/apt/archives/partial ]; then
    log_info "Recreating default internal APT cache directories..."
    sudo mkdir -p /var/cache/apt/archives/partial
    sudo chown -R _apt:root /var/cache/apt/archives
fi

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

# Convert a CIDR prefix length (e.g. 24) into a dotted-decimal netmask.
cidr_to_netmask() {
    local prefix=$1
    local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    printf "%d.%d.%d.%d\n" \
        $(( (mask >> 24) & 0xFF )) \
        $(( (mask >> 16) & 0xFF )) \
        $(( (mask >> 8)  & 0xFF )) \
        $(( mask & 0xFF ))
}

# Return 0 if $1 (an IP) is inside the subnet formed by $2 (subnet IP)
# and $3 (prefix length). Return 1 otherwise.
in_subnet() {
    local ip=$1 base=$2 prefix=$3
    local a b c d e f g h
    IFS=. read -r a b c d <<< "$ip"
    IFS=. read -r e f g h <<< "$base"
    local ip_num=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    local base_num=$(( (e << 24) | (f << 16) | (g << 8) | h ))
    local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    [ $(( (ip_num ^ base_num) & mask )) -eq 0 ]
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
# Disable the BeagleBone eMMC flasher trigger.
#
# The eMMC ships with /boot/uEnv.txt containing:
#   cmdline=init=/usr/sbin/init-beagle-flasher
#
# When active, this line causes the board to reflash its eMMC from the SD
# card on a subsequent boot, IF the SD is detected in time and contains a
# flasher image. SD detection is non-deterministic on the AM335x, so the
# flash can fire on the first reboot, the second, or never. This is the
# classic "worked once, then died after another reboot" pattern.
#
# The bootstrap wipes the SD's boot sector but cannot wipe the SD's
# filesystem, so a filesystem-based flasher marker survives. The trigger
# on the eMMC side is the reliable place to disable.
#
# To deliberately reflash the eMMC, run with:
#   KEEP_FLASHER=1 ./bootstrap-node.sh
# and this block is skipped.
# ---------------------------------------------------------------------------
if [ "${KEEP_FLASHER:-0}" != "1" ]; then
    if [ -f /boot/uEnv.txt ]; then
        if grep -qE '^[[:space:]]*cmdline=init=/usr/sbin/init-beagle-flasher' /boot/uEnv.txt; then
            log_warn "eMMC flasher trigger is active. Disabling so the next boot cannot reflash."
            ts=$(date +%Y%m%d%H%M%S)
            sudo cp /boot/uEnv.txt "/boot/uEnv.txt.bak.$ts"
            sudo sed -i 's|^[[:space:]]*\(cmdline=init=/usr/sbin/init-beagle-flasher.*\)|# [bootstrap] disabled: \1|' /boot/uEnv.txt

            # Confirm the change actually landed before proceeding.
            if ! grep -qE '^[[:space:]]*# \[bootstrap\] disabled:.*init-beagle-flasher' /boot/uEnv.txt; then
                log_error "Failed to disable the flasher trigger in /boot/uEnv.txt."
                log_error "Check that /boot is not mounted read-only:"
                log_error "  mount | grep ' /boot '"
                log_error "Refusing to continue; the next boot may overwrite this system."
                exit 1
            fi
            log_success "Flasher trigger disabled. Backup saved as /boot/uEnv.txt.bak.$ts"
        else
            log_info "eMMC flasher trigger is not present (or already disabled)."
        fi
    else
        log_warn "/boot/uEnv.txt not found; cannot verify flasher state."
    fi
fi

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
DEVICE_CIDR=""
DEVICE_PREFIX=""
DEVICE_NETMASK=""
ROUTER_IP=""
CONTROLLER_IP=""
PRIMARY_IF=""
RANDOM_MAC=""
NEED_HOST_ROUTE="false"
NET_CONFIG_PENDING="false"
IFACE_CONF="/etc/network/interfaces.d/quantum-node"
SRC_MARKER="/etc/network/.quantum_managed_source_line"

# ---------------------------------------------------------------------------
# --- Phase 0: Network Configuration ---
# ---------------------------------------------------------------------------
# "Installed" means the network config file exists AND the main
# interfaces file actually sources the interfaces.d directory.
#
# On the factory Debian Buster image, /etc/network/interfaces sometimes
# ships without a source-directory line. If that line is missing, the
# static config in interfaces.d/quantum-node is silently ignored, the
# interface comes up with a DHCP lease at boot, and the controller
# becomes unreachable. Requiring both conditions makes a re-run of the
# bootstrap repair that case automatically.
NET_INSTALLED=1
if [ -f "$IFACE_CONF" ] && \
   grep -qE '^[[:space:]]*(auto|allow-hotplug)[[:space:]]' "$IFACE_CONF" && \
   grep -qE '^[[:space:]]*iface[[:space:]]' "$IFACE_CONF" && \
   grep -qE '^source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces 2>/dev/null; then
    NET_INSTALLED=0
fi

if should_run_phase "Phase 0 (Network Configuration)" "$NET_INSTALLED"; then
    log_info "Preparing network configuration..."

    # --- Detect primary network interface ---
    # Prefer the interface the kernel would actually use to reach the
    # outside world. Fall back to the first UP, non-virtual, non-lo link.
    # Never trust /etc/network/interfaces — it may already have been
    # rewritten by a previous run.
    PRIMARY_IF=$(ip -o route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [ -z "$PRIMARY_IF" ]; then
        PRIMARY_IF=$(ip -o -4 route show to default 2>/dev/null \
            | awk '{print $5}' | head -n1)
    fi
    if [ -z "$PRIMARY_IF" ]; then
        PRIMARY_IF=$(ip -o link show up 2>/dev/null | awk -F': ' \
            '$2 != "lo" && $2 !~ /^(docker|veth|br-|tun|tap)/ {print $2; exit}')
    fi

    if [ -z "$PRIMARY_IF" ]; then
        log_error "Could not auto-detect a primary network interface. Aborting Phase 0."
    else
        log_info "Primary network interface detected: $PRIMARY_IF"

        # --- Ask user for network configuration ---
        DEVICE_CIDR=$(prompt_with_default "Enter the IP address and prefix length for THIS device (node)" "172.21.128.254/24")
        ROUTER_IP=$(prompt_with_default "Enter the default router IP" "172.21.128.1")
        CONTROLLER_IP=$(prompt_with_default "Enter the IP address of the Network Controller" "172.21.2.23")

        # Split CIDR into IP and prefix, then derive the dotted netmask.
        DEVICE_IP="${DEVICE_CIDR%%/*}"
        DEVICE_PREFIX="${DEVICE_CIDR##*/}"
        DEVICE_NETMASK="$(cidr_to_netmask "$DEVICE_PREFIX")"

        log_info "Device:          $DEVICE_IP/$DEVICE_PREFIX (netmask $DEVICE_NETMASK)"
        log_info "Default router:  $ROUTER_IP"
        log_info "Controller:      $CONTROLLER_IP"

        # Determine whether the controller is on the same IP subnet as the
        # device. If yes, the kernel's directly-connected route would send
        # traffic to the controller over L2, which fails when the controller
        # sits behind the default router. A /32 host route overrides that.
        # If the controller is on a different subnet, the default route
        # already reaches it and no extra route is needed.
        NEED_HOST_ROUTE=false
        if in_subnet "$CONTROLLER_IP" "$DEVICE_IP" "$DEVICE_PREFIX"; then
            NEED_HOST_ROUTE=true
            log_info "Controller is on the same subnet as this node; a /32 route via the default router will be added."
        else
            log_info "Controller is on a different subnet; the default route will reach it."
        fi

        # Persist the random MAC separately so that a broken/removed
        # interfaces.d/quantum-node cannot cause us to roll a new MAC.
        MAC_STORE="/etc/network/.quantum_mac"
        RANDOM_MAC=""
        if [ -f "$MAC_STORE" ]; then
            RANDOM_MAC=$(sudo cat "$MAC_STORE" 2>/dev/null | tr -d '[:space:]')
        fi
        if [ -z "$RANDOM_MAC" ] && [ -f "$IFACE_CONF" ]; then
            RANDOM_MAC=$(grep -i "hwaddress ether" "$IFACE_CONF" 2>/dev/null | awk '{print $3}')
        fi
        if [ -z "$RANDOM_MAC" ]; then
            RANDOM_MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
                $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
                $((RANDOM % 256)) $((RANDOM % 256)))
            echo "$RANDOM_MAC" | sudo tee "$MAC_STORE" > /dev/null
            sudo chmod 644 "$MAC_STORE"
            log_info "Generated new random MAC: $RANDOM_MAC (stored at $MAC_STORE)"
        else
            log_info "Reusing persistent MAC: $RANDOM_MAC"
        fi

        NET_CONFIG_PENDING="true"

        # We deliberately do NOT add a fallback default route here.
        # On a BeagleBone that already has a working default route, adding
        # a second default via a hardcoded gateway can shadow the real one
        # and take the node off the network for the rest of the session.
        # If apt needs DNS during this run, it will use whatever the
        # currently active config provides; if that fails, we simply warn
        # and continue. The persistent config is written at the end.
        if ! getent hosts deb.debian.org >/dev/null 2>&1; then
            log_warn "DNS is currently not resolving. apt may not work during this run."
            log_warn "Not touching routes or /etc/resolv.conf; the persistent"
            log_warn "config is applied at the end of the script and takes effect"
            log_warn "on the next reboot."
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

        # -----------------------------------------------------------------
        # Identify the SD card safely.
        #
        # The AM335x kernel assigns mmcblk0 and mmcblk1 based on probe
        # order at boot, not on hardware. The eMMC can end up as either
        # name depending on whether the SD card was detected in time and
        # what else is on the bus. Never trust the name.
        #
        # The SD card is identified by exclusion:
        #   (a) it is an mmcblk block device,
        #   (b) its name matches ^mmcblk[0-9]+$ (this excludes the eMMC
        #       boot partitions mmcblkXboot0 / mmcblkXboot1 which are also
        #       type=disk on some kernels), and
        #   (c) it is NOT the parent disk of the root filesystem,
        #   (d) it is NOT the parent of any currently mounted filesystem.
        #
        # Any candidate that fails (c) or (d) is skipped, so this cannot
        # accidentally target the eMMC.
        # -----------------------------------------------------------------
        ROOT_SRC=$(findmnt -n -o SOURCE /)
        ROOT_DISK=$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null | head -n1)
        log_info "Root filesystem: $ROOT_SRC (parent disk: ${ROOT_DISK:-unknown})"

        SD_DISK=""
        while read -r dev type; do
            [ "$type" = "disk" ]              || continue
            [[ "$dev" =~ ^mmcblk[0-9]+$ ]]    || continue
            [ "$dev" = "$ROOT_DISK" ]         && continue

            # Skip any device whose size matches the BeagleBone's on-board
            # eMMC. The BBB ships with a 4 GB nominal (3.6 GiB actual) eMMC.
            # If the node boots from the SD card rather than the eMMC, the
            # root disk is mmcblk0 and the eMMC is mmcblk1 — the exclusion
            # above would leave the eMMC as the only candidate, and this
            # script would then zero and repartition the eMMC. Checking the
            # size protects against that.
            SECTORS=$(cat /sys/block/$dev/size 2>/dev/null || echo 0)
            SIZE_GB=$(( SECTORS * 512 / 1000000000 ))

            if [ "$SIZE_GB" -ge 3 ] && [ "$SIZE_GB" -le 4 ]; then
                log_warn "Skipping /dev/$dev: size ${SIZE_GB}GB matches the eMMC's known capacity."
                continue
            fi

            # Refuse any device with a mounted child
            if lsblk -nlo MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -qv '^$'; then
                log_warn "Skipping /dev/$dev: has mounted partitions"
                continue
            fi

            SD_DISK="/dev/$dev"
            break
        done < <(lsblk -ndo NAME,TYPE 2>/dev/null)

        if [ -z "$SD_DISK" ] || [ ! -b "$SD_DISK" ]; then
            log_warn "No candidate SD card device found."
            log_warn "  If the SD is inserted, check: lsblk -o NAME,SIZE,TYPE,MOUNTPOINT"
            log_warn "  Skipping SD offload; logs and apt cache stay on eMMC."
        else
            log_info "SD card identified by exclusion: $SD_DISK"

            # -----------------------------------------------------------------
            # Wipe first 10 MB and repartition.
            #
            # The zeroing destroys any legacy U-Boot flasher header that
            # would otherwise make the SD bootable and re-flash the eMMC
            # on the next power cycle. It is safe here because we are
            # about to reformat the whole card.
            # -----------------------------------------------------------------
            log_info "Wiping $SD_DISK and creating a fresh ext4 partition..."
            sudo systemctl stop quantum-grpc-agent quantum-netconf-agent quantum-gnmi-agent quantum-gnoi-agent 2>/dev/null || true
            sudo umount /mnt/sdcard 2>/dev/null || true
            sudo umount -l ${SD_DISK}* 2>/dev/null || true

            sudo dd if=/dev/zero of="$SD_DISK" bs=1M count=10 status=none || true

            sudo parted -s "$SD_DISK" mklabel msdos
            sudo parted -s "$SD_DISK" mkpart primary ext4 0% 100%
            sudo partprobe "$SD_DISK"

            # Wait for the kernel to publish the new partition node.
            # udev can take a moment on slower SD cards; use a bounded loop
            # instead of a fixed sleep.
            SD_TARGET="${SD_DISK}p1"
            for _ in $(seq 1 10); do
                [ -b "$SD_TARGET" ] && break
                sleep 0.5
            done

            if [ ! -b "$SD_TARGET" ]; then
                log_error "Partition $SD_TARGET did not appear after partprobe."
                log_error "  SD offload skipped; logs and apt cache stay on eMMC."
            else
                sudo mkfs.ext4 -F "$SD_TARGET"

                sudo mkdir -p /mnt/sdcard
                if ! sudo mount "$SD_TARGET" /mnt/sdcard; then
                    log_error "Failed to mount $SD_TARGET on /mnt/sdcard."
                    log_error "  SD offload skipped; logs and apt cache stay on eMMC."
                else
                    # -----------------------------------------------------------------
                    # Resilient fstab entry, keyed by UUID.
                    #
                    # Do NOT mount by device name. If the SD card is absent
                    # at boot, or if the kernel swaps mmcblk0/mmcblk1 between
                    # boots, a device-name entry points at the wrong device
                    # or blocks boot waiting for a device that never appears.
                    # UUIDs travel with the filesystem and are immune to that.
                    #
                    #   nofail                    : do not block boot if SD is absent
                    #   x-systemd.device-timeout  : cap the wait
                    # -----------------------------------------------------------------
                    SD_UUID=$(sudo blkid -s UUID -o value "$SD_TARGET")
                    if [ -z "$SD_UUID" ]; then
                        log_error "Could not read UUID of $SD_TARGET."
                        log_error "  SD offload skipped; logs and apt cache stay on eMMC."
                    else
                        FSTAB_LINE="UUID=$SD_UUID /mnt/sdcard auto defaults,nofail,x-systemd.device-timeout=10 0 2"

                        # Remove any prior /mnt/sdcard entry regardless of how
                        # it was keyed (device name from an older script, a
                        # stale UUID, etc.)
                        sudo sed -i '\|\s/mnt/sdcard\s|d' /etc/fstab
                        echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
                        log_info "fstab entry written: $FSTAB_LINE"

                        sudo chown -R "$USER:$USER" /mnt/sdcard
                        sudo mkdir -p /mnt/sdcard/apt-cache/partial
                        sudo chown -R _apt:root /mnt/sdcard/apt-cache

                        # Idempotent: only replace the local dir if it is not
                        # already the expected symlink.
                        if [ ! -L /var/cache/apt/archives ] || \
                           [ "$(readlink /var/cache/apt/archives)" != "/mnt/sdcard/apt-cache" ]; then
                            sudo rm -rf /var/cache/apt/archives
                            sudo ln -s /mnt/sdcard/apt-cache /var/cache/apt/archives
                        fi
                        log_success "SD card ready: $SD_TARGET (UUID $SD_UUID) at /mnt/sdcard."
                    fi
                fi
            fi
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
# --- Phase 6: Apply persistent network configuration (IP/MAC/DNS) ---
# ---------------------------------------------------------------------------
if [ "$NET_CONFIG_PENDING" = "true" ] && [ -n "$PRIMARY_IF" ]; then
    log_info "Writing persistent network configuration to $IFACE_CONF..."

    # -----------------------------------------------------------------
    # Make interfaces.d authoritative at boot.
    #
    # ifupdown reads /etc/network/interfaces top to bottom. The factory
    # Debian Buster image ships with a source-directory line at the top
    # of the file and an eth0 dhcp block further down. Because the DHCP
    # block comes last, it wins on every boot, and the static config in
    # interfaces.d/quantum-node is silently overridden. The node then
    # comes up on a DHCP lease and the controller becomes unreachable.
    #
    # Three changes make the outcome deterministic:
    #   1. Back up /etc/network/interfaces once.
    #   2. Comment out any auto/iface block for our interface in the
    #      main file, so it cannot compete.
    #   3. Remove every source-directory line for interfaces.d and
    #      append a single one at the very end.
    # -----------------------------------------------------------------
    # Always start from the pristine original. If we start from the
    # already-normalised file, each run adds another layer of
    # "# [bootstrap] disabled:" lines and the file grows unbounded.
    # The backup is made once and reused; re-running bootstrap is then
    # truly idempotent.
    if [ ! -f "${IFACE_CONF}.main.bak" ]; then
        sudo cp /etc/network/interfaces "${IFACE_CONF}.main.bak"
        log_info "Backed up /etc/network/interfaces to ${IFACE_CONF}.main.bak"
    else
        log_info "Restoring pristine /etc/network/interfaces from backup before re-normalising."
        if ! sudo cp "${IFACE_CONF}.main.bak" /etc/network/interfaces; then
            log_error "Could not restore /etc/network/interfaces from backup. Aborting Phase 6."
            exit 1
        fi
    fi

    log_info "Normalising /etc/network/interfaces..."
    sudo python3 - "$PRIMARY_IF" <<'PYEOF'
import re, sys
iface = sys.argv[1]
path = "/etc/network/interfaces"
with open(path) as f:
    lines = f.readlines()

out = []
in_disabled_block = False
for line in lines:
    s = line.rstrip("\n")
    t = s.strip()

    # Blank lines and pure comments end a stanza.
    if not t or t.startswith("#"):
        in_disabled_block = False
        out.append(line)
        continue

    new_stanza = bool(re.match(
        r"^(auto|iface|source|source-directory|mapping|allow-)\b", t))
    if new_stanza:
        in_disabled_block = False

    if re.match(rf"^auto\s+{re.escape(iface)}\s*$", t) or \
       re.match(rf"^iface\s+{re.escape(iface)}\b", t):
        out.append("# [bootstrap] disabled: " + s + "\n")
        in_disabled_block = True
        continue

    if in_disabled_block and (s.startswith(" ") or s.startswith("\t")):
        out.append("# " + s + "\n")
        continue

    if re.match(r"^source(-directory)?\s+/etc/network/interfaces\.d", t):
        # Drop the old source line entirely; we add exactly one at the end.
        continue

    out.append(line)

# Exactly one source-directory directive, at the very end.
out.append("\n# [bootstrap] interfaces.d must be read last so it wins.\n")
out.append("source-directory /etc/network/interfaces.d\n")

with open(path, "w") as f:
    f.writelines(out)
PYEOF

    sudo touch "$SRC_MARKER"
    log_info "Interfaces file normalised."

    sudo mkdir -p /etc/network/interfaces.d

    # Add source-directory line only if not already present. Marker file lets
    # the uninstaller know we were the one that added it.
    if ! grep -qE '^source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces 2>/dev/null; then
        echo "source-directory /etc/network/interfaces.d" | sudo tee -a /etc/network/interfaces > /dev/null
        sudo touch "$SRC_MARKER"
        log_info "Added source-directory line (marker $SRC_MARKER set for later cleanup)."
    fi

    # Emit the interface config line by line. The /32 host route to the
    # controller is only emitted when the controller is on the SAME subnet
    # as this node — that is the only case where the kernel's
    # directly-connected route would try to reach the controller over L2
    # and fail because the controller is actually behind the router.
    NEW_CONF=$(mktemp)
    {
        echo "# Quantum Node Switching - managed by bootstrap-node.sh"
        echo "# Node: $DEVICE_IP/$DEVICE_PREFIX   Router: $ROUTER_IP   Controller: $CONTROLLER_IP"
        echo "auto $PRIMARY_IF"
        echo "iface $PRIMARY_IF inet static"
        echo "    address $DEVICE_IP"
        echo "    netmask $DEVICE_NETMASK"
        echo "    gateway $ROUTER_IP"
        echo "    hwaddress ether $RANDOM_MAC"
        echo "    dns-nameservers $CONTROLLER_IP 8.8.8.8 1.1.1.1"
        if [ "$NEED_HOST_ROUTE" = "true" ]; then
            echo "    # Controller is on the same subnet as this node, but sits behind"
            echo "    # the default router. Pin it with a /32 host route so traffic is"
            echo "    # not sent over the L2 segment looking for an unreachable peer."
            echo "    up   ip route add $CONTROLLER_IP/32 via $ROUTER_IP || true"
            echo "    down ip route del $CONTROLLER_IP/32 via $ROUTER_IP || true"
        fi
    } > "$NEW_CONF"

    if sudo test -f "$IFACE_CONF" && sudo diff -q "$NEW_CONF" "$IFACE_CONF" >/dev/null 2>&1; then
        log_info "Interface config is already up to date; not rewriting and not rebooting for it."
        NET_CONFIG_PENDING="false"
        rm -f "$NEW_CONF"
    else
        sudo install -m 0644 -o root -g root "$NEW_CONF" "$IFACE_CONF"
        rm -f "$NEW_CONF"
        log_success "Persistent interface config written."
        NET_CONFIG_PENDING="true"
    fi

    # Update the on-disk resolv.conf: Controller first, public resolvers
    # as fallback.
    #
    # The file may be immutable from a previous run of this script. Clear
    # the attribute first so rm and tee can proceed. The attribute is
    # re-applied at the end of this block.
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        sudo chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    sudo rm -f /etc/resolv.conf
    sudo tee /etc/resolv.conf > /dev/null <<EOF
# Managed by bootstrap-node.sh
nameserver $CONTROLLER_IP
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:1 attempts:1
EOF
    log_success "Persistent /etc/resolv.conf written (controller + public fallback)."

    # Protect the file from DHCP rewrites, but ONLY if the system does
    # not use resolvconf or systemd-resolved to manage it.
    #
    # If resolvconf is present and active, it tries to rewrite
    # /etc/resolv.conf each time ifupdown brings up an interface with a
    # dns-nameservers line. Making the file immutable at that point makes
    # resolvconf fail, which makes ifup fail, which makes
    # networking.service report failure at every boot. The node still
    # has its IP, but the boot sequence is left with a failed unit and
    # some services may not start.
    #
    # Detect resolvconf and systemd-resolved and skip the immutable flag
    # when either is in use. The DNS entry is still rewritten on every
    # bootstrap run, which is enough for this deployment.
    RESOLV_MANAGED=false
    if dpkg -l resolvconf 2>/dev/null | grep -q '^ii'; then
        RESOLV_MANAGED=true
        log_info "resolvconf detected; skipping immutable flag on /etc/resolv.conf."
    fi
    if systemctl is-enabled systemd-resolved 2>/dev/null | grep -q enabled; then
        RESOLV_MANAGED=true
        log_info "systemd-resolved detected; skipping immutable flag on /etc/resolv.conf."
    fi
    if [ -L /etc/resolv.conf ]; then
        RESOLV_MANAGED=true
        log_info "/etc/resolv.conf is a symlink; skipping immutable flag."
    fi

    if [ "$RESOLV_MANAGED" = false ]; then
        sudo chattr +i /etc/resolv.conf 2>/dev/null || \
            log_warn "Could not set immutable attribute on /etc/resolv.conf."
        log_info "Set immutable attribute on /etc/resolv.conf."
    fi

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
# --- Final step: conditional reboot ---
#
# A reboot is only required when the persistent network configuration was
# (re)written in this run. Everything else (systemd units, kernel sysctl,
# package installs, SD card fstab) takes effect immediately or on the next
# mount. Skipping the reboot keeps an already-configured node running with
# no interruption.
# ---------------------------------------------------------------------------
if [ "$NET_CONFIG_PENDING" = "true" ]; then
    if [ "${NO_REBOOT:-0}" = "1" ]; then
        log_warn "NO_REBOOT=1 set: skipping reboot. Reboot manually to apply network config."
    else
        log_warn "Network configuration was written; a reboot is required to apply it."
        sync
        sleep 3
        log_warn "If this is a remote SSH session, it will now disconnect."
        sleep 2
        sudo reboot -f
    fi
else
    log_success "No network changes were made in this run; skipping reboot."
    log_info "Node bootstrap complete."
fi
