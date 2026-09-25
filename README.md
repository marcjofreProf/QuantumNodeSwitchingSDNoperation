# QuantumNodeSwitchingSDNoperation
Project to develop the quantum node operation in SDN switching

# Quantum Node Switching: SDN Operation Agent

This repository contains the node-level execution agent and hardware-abstraction code for the **Quantum-SDN Switching Architecture**. It is designed to run on a BeagleBone Black (BBB) acting as the local controller for physical optical circuit switches.

This project works in tandem with the central control plane repository: [QuantumSwitchingSDNarchitecture](https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git), which houses the µONOS, ETSI OSM, and Kubernetes deployments; and the operations and service repository: [QuantumServiceOperationSDNarchitecture](https://github.com/marcjofreProf/QuantumServiceOperationSDNarchitecture.git), which supports operations and services for users.

## Architecture & Concept

To achieve dynamic quantum path provisioning without control-plane bottlenecks, this node agent features a **dual-protocol architecture**, supporting both high-speed operations and standard interoperability:

1. **Fast-Path gNMI and gNOI (gRPC Network Operations Interface):** Bypasses legacy protocols to communicate directly with the µONOS SDN controller. It receives binary-serialized Protocol Buffers (Protobufs) representing operational state changes with near-zero software latency.
2. **Standard NETCONF/YANG:** Hosts a parallel standard SSH/XML server utilizing YANG data models, ensuring full interoperability with traditional SDN orchestrators (like ETSI OSM or OpenDaylight).
3. **Node Processing (BBB):** The lightweight agents on the BeagleBone Black translate incoming network commands (from either gNOI or NETCONF) into TTL logic levels via the device's GPIO pins.
4. **Physical Switching:** An opto-decoupled interface safely steps the TTL signals to drive high-speed MEMS or solid-state optical matrix switches.

This circuit-switched data plane achieves physical switching delays ranging from **< 20 milliseconds down to sub-millisecond speeds**, ensuring quantum states pass through without measurement or degradation.

## Hardware Requirements
* **Compute:** BeagleBone Black (Debian Linux).
* **Interface:** Custom or COTS Opto-Isolator / Optocoupler board (to protect the BBB from voltage spikes and map 3.3V GPIO to the switch's required logic levels).
* **Switching:** MEMS or Solid-State Optical Matrix Switch (TTL controllable).

## Repository Structure
* `/agent/` - The core gNOI server (Go/Python) listening for µONOS commands.
* `/driver/` - Hardware abstraction layer (HAL) for BBB GPIO pin manipulation (using `libgpiod`).
* `/proto/` - Local copies of the gNOI/gNMI protocol buffer definitions.
* `/yang/` - Local copies of the NETCONF YANG data models.
* `/systemd/` - Daemons to run agents as a persistent background service.

### Accelerated gRPC Installation (Pre-built Wheels)

Building heavy C++ Python libraries like `grpcio` and `protobuf` from source directly on the BeagleBone Black (ARM32v7, 512MB RAM) is incredibly slow - taking up to 12 hours - and requires generating massive temporary swap partitions to prevent memory crashes.

To solve this, this repository uses a **host-based cross-compilation** strategy. By leveraging Docker and QEMU on a standard desktop/laptop, we emulate the BBB's 32-bit Debian Buster environment and compile Python Wheels (`.whl` files) in a fraction of the time.

** Good news: This has already been done!**
The pre-compiled wheel binaries are already stored in the `./builds` directory of this repository. When you run `bootstrap-node.sh` on the BBB, it will automatically detect these local files and install them in seconds. If needed to re-compile them, execute ./BBBgrpcioCrossLinkingBuild.sh in folder builds.

#### Rebuilding the Wheels (For Maintainers)
If you need to update the version of gRPC or rebuild the wheels for any reason, you can do so on any Linux/macOS/WSL machine with Docker installed:

1. Ensure Docker is running on your host machine.
2. Navigate to the `builds` directory:
   ```bash
   cd builds
   sudo chmod +x ./BBBgrpcioCrossLinkingBuild.sh
   ./BBBgrpcioCrossLinkingBuild.sh
