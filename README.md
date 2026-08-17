# QuantumNodeSwitchingSDNoperation
Project to develop the quantum node operation in SDN switching

# Quantum Node Switching: SDN Operation Agent

This repository contains the node-level execution agent and hardware-abstraction code for the **Quantum-SDN Switching Architecture**. It is designed to run on a BeagleBone Black (BBB) acting as the local controller for physical optical circuit switches.

This project works in tandem with the central control plane repository: [QuantumSwitchingSDNarchitecture](https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git), which houses the µONOS, ETSI OSM, and Kubernetes deployments.

## Architecture & Concept

To achieve dynamic quantum path provisioning without control-plane bottlenecks, this node agent bypasses legacy protocols (like NETCONF/XML) and communicates directly with the µONOS SDN controller using **gNOI (gRPC Network Operations Interface)**.

1. **Southbound gNOI:** µONOS sends binary-serialized Protocol Buffers (Protobufs) representing operational port-mapping state changes.
2. **Node Processing (BBB):** A lightweight gNOI server on the BeagleBone Black receives these state changes with near-zero software latency.
3. **Hardware Execution:** The BBB translates these commands into TTL logic levels via its GPIO pins.
4. **Physical Switching:** An opto-decoupled interface safely steps the TTL signals to drive high-speed MEMS or solid-state optical matrix switches (e.g., Agiltron, Thorlabs, Keysight, DiCon).

This circuit-switched data plane achieves physical switching delays ranging from **< 20 milliseconds down to sub-millisecond speeds**, ensuring quantum states (like entangled single photons) pass through without measurement or degradation.

## Hardware Requirements
* **Compute:** BeagleBone Black (Debian Linux).
* **Interface:** Custom or COTS Opto-Isolator / Optocoupler board (to protect the BBB from voltage spikes and map 3.3V GPIO to the switch's required logic levels).
* **Switching:** MEMS or Solid-State Optical Matrix Switch (TTL controllable).

## Repository Structure
* `/agent/` - The core gNOI server (Go/Python) listening for µONOS commands.
* `/driver/` - Hardware abstraction layer (HAL) for BBB GPIO pin manipulation (using `libgpiod`).
* `/proto/` - Local copies of the gNOI/gNMI protocol buffer definitions.
* `/systemd/` - Daemons to run the agent as a persistent background service.

### Accelerated gRPC Installation (Pre-built Wheels)

Building heavy C++ Python libraries like `grpcio` and `protobuf` from source directly on the BeagleBone Black (ARM32v7, 512MB RAM) is incredibly slow—taking up to 12 hours—and requires generating massive temporary swap partitions to prevent memory crashes.

To solve this, this repository uses a **host-based cross-compilation** strategy. By leveraging Docker and QEMU on a standard desktop/laptop, we emulate the BBB's 32-bit Debian Buster environment and compile Python Wheels (`.whl` files) in a fraction of the time.

** Good news: This has already been done!**
The pre-compiled wheel binaries are already stored in the `./builds` directory of this repository. When you run `bootstrap-node.sh` on the BBB, it will automatically detect these local files and install them in seconds. If needed to re-compile them, execute ./BBBgrpcioCrossLinkingBuild.sh in folder builds.

#### Rebuilding the Wheels (For Maintainers)
If you need to update the version of gRPC or rebuild the wheels for any reason, you can do so on any Linux/macOS/WSL machine with Docker installed:

1. Ensure Docker is running on your host machine.
2. Navigate to the `builds` directory:
   ```bash
   cd builds

## Quickstart (BeagleBone Black)

A bootstrap script is provided to instantly configure a fresh BeagleBone Black with the required dependencies, GPIO libraries, gRPC tooling, and folder structure.

**1. Clone the repository on the BeagleBone Black**
```bash
git clone [https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git](https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git)
cd QuantumNodeSwitchingSDNoperation
```

**2. Make the bootstrap script executable**
```bash
sudo chmod +x ./bootstrap-node.sh
```

**3. Run the setup (requires sudo privileges)**
```bash
./bootstrap-node.sh
```

> **Note on Storage:** Insert the microSD card *after* the system has booted. The bootstrap script can automatically detect, format (to ext4), and mount an inserted microSD card to seamlessly offload heavy C++ compilation artifacts and store persistent agent logs, bypassing the BeagleBone Black's limited eMMC storage and preventing premature flash wear.

> **Note on BBB apt repositories:** In `/home/debian/`, create the directory `Scripts` (`mkdir Scripts`). Then, download the repository.

### Storage Management (SD Card Symlinking)
To conserve internal storage on the edge nodes, download the project directory to an external SD card and create a symbolic link. This routes all data to the SD card while allowing the system and scripts to seamlessly access the files at their original `~/Scripts` location.

```bash
sudo mount /dev/mmcblk0p1 /mnt/sdcard
sudo mkdir -p /mnt/sdcard/Scripts
sudo chown -R debian:debian /mnt/sdcard/Scripts

cd ~/Scripts

# Create a symbolic link in the home directory pointing to the SD card
ln -s /mnt/sdcard/Scripts ~/Scripts

### Issues with packet repositories
If you experience issues with `apt` and `apt-get`, edit your sources list (`sudo nano /etc/apt/sources.list`) to match the following archive mirrors for Debian Buster:

```text
deb [http://archive.debian.org/debian](http://archive.debian.org/debian) buster main contrib non-free
#deb-src [http://deb.debian.org/debian](http://deb.debian.org/debian) buster main contrib non-free

#deb [http://security.debian.org/debian-security](http://security.debian.org/debian-security) buster/updates main contrib non-free
#deb-src [http://security.debian.org/debian-security](http://security.debian.org/debian-security) buster/updates main contrib non-free

deb [http://archive.debian.org/debian](http://archive.debian.org/debian) buster-updates main contrib non-free
#deb-src [http://deb.debian.org/debian](http://deb.debian.org/debian) buster-updates main contrib non-free

#Kernel source (repos.rcn-ee.com) : [https://github.com/RobertCNelson/linux-stable-rcn-ee](https://github.com/RobertCNelson/linux-stable-rcn-ee)
#
#git clone [https://github.com/RobertCNelson/linux-stable-rcn-ee](https://github.com/RobertCNelson/linux-stable-rcn-ee)
#cd ./linux-stable-rcn-ee
#git checkout `uname -r` -b tmp

deb [arch=armhf signed-by=/usr/share/keyrings/rcn-ee-archive-keyring.gpg] [http://repos.rcn-ee.com/debian/](http://repos.rcn-ee.com/debian/) buster main
#deb-src [arch=armhf signed-by=/usr/share/keyrings/rcn-ee-archive-keyring.gpg] [http://repos.rcn-ee.com/debian/](http://repos.rcn-ee.com/debian/) buster main
```

---

## Manual Hardware Testing

Before initiating the gNOI agent, it is highly recommended to verify the physical connections to the MEMS Optical Matrix. A standalone test script is provided to cycle the crossconnect relays without requiring network connectivity or the gRPC server.

### Executing the Test

Ensure your `driver/pin_mappings.json` is correctly configured for your specific hardware, then execute the test script using the virtual environment:

```bash
sudo ./venv/bin/python3 ./test/test_manual_switching_hardware.py
```

---

## Running the gNOI Agent

The gNOI Agent (`agent/gnoi_agent.py`) is the brain of the node. It hosts a gRPC server (default port `50051`) that listens for network commands from the SDN orchestrator and translates them into physical hardware actions via the driver.

### Automatic Execution (Recommended)

During the execution of `bootstrap-node.sh`, a Systemd service is automatically generated. The agent will run in the background and start automatically on boot (sudo systemctl enable quantum-gnoi-agent).

To manage the service, use standard `systemctl` commands:

```bash
sudo systemctl status quantum-gnoi-agent
sudo systemctl start quantum-gnoi-agent
sudo systemctl restart quantum-gnoi-agent
sudo systemctl stop quantum-gnoi-agent
```

To view live network and hardware logs:

```bash
sudo journalctl -u quantum-gnoi-agent -f
```

### Manual Execution (For Debugging)

If you need to run the agent interactively to debug gRPC connectivity, ensure the Systemd service is stopped, then execute the script using the virtual environment:

```bash
sudo ./venv/bin/python3 agent/gnoi_agent.py
```

Manual Execution (For Debugging)
If you need to run the agent interactively to debug gRPC connectivity, ensure the Systemd service is stopped, then execute the script using the virtual environment:

sudo ./venv/bin/python3 agent/gnoi_agent.py


## Teardown & System Cleanup

To stop the agent systemd service, unmount offloaded SD card storage, remove virtual environments, and clean untracked files from the node workspace, run the uninstall script:

```bash
sudo chmod +x uninstall-bootstrap-node.sh
./uninstall-bootstrap-node.sh
