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

## Quickstart (BeagleBone Black)

A bootstrap script is provided to instantly configure a fresh BeagleBone Black with the required dependencies, GPIO libraries, gRPC tooling, and folder structure.

```bash
# 1. Clone the repository on the BeagleBone Black
git clone https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git
cd QuantumNodeSwitchingSDNoperation

# 2. Make the bootstrap script executable
sudo chmod +x ./bootstrap-node.sh

# 3. Run the setup (requires sudo privileges)
./bootstrap-node.sh

Note on Storage: Insert sdcard after the system has booted. The bootstrap script can automatically detect, format (to ext4), and mount an inserted microSD card to seamlessly offload heavy C++ compilation artifacts and store persistent agent logs, bypassing the BeagleBone Black's limited eMMC storage and preventing premature flash wear.

Note on BBB apt repositories: In /home/debian/, create the directory Scripts (mkdir Scripts). Then, download the repository:
# Note for apt and apt-get 
# sudo nano /etc/apt/sources.list

deb http://archive.debian.org/debian buster main contrib non-free
#deb-src http://deb.debian.org/debian buster main contrib non-free

#deb http://security.debian.org/debian-security buster/updates main contrib non-free
#deb-src http://security.debian.org/debian-security buster/updates main contrib non-free

deb http://archive.debian.org/debian buster-updates main contrib non-free
#deb-src http://deb.debian.org/debian buster-updates main contrib non-free

#Kernel source (repos.rcn-ee.com) : https://github.com/RobertCNelson/linux-stable-rcn-ee
#
#git clone https://github.com/RobertCNelson/linux-stable-rcn-ee
#cd ./linux-stable-rcn-ee
#git checkout `uname -r` -b tmp
deb [arch=armhf signed-by=/usr/share/keyrings/rcn-ee-archive-keyring.gpg] http://repos.rcn-ee.com/debian/ buster main
#deb-src [arch=armhf signed-by=/usr/share/keyrings/rcn-ee-archive-keyring.gpg] http://repos.rcn-ee.com/debian/ buster main


## Manual Hardware Testing

Before initiating the gNOI agent, it is highly recommended to verify the physical connections to the MEMS Optical Matrix. A standalone test script is provided to cycle the crossconnect relays without requiring network connectivity or the gRPC server.

### Executing the Test

Ensure your `driver/pin_mappings.json` is correctly configured for your specific hardware, then execute the test script using the virtual environment:

```bash
sudo ./venv/bin/python3 ./test/test_manual_switching_hardware.py
