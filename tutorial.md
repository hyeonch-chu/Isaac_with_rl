# Isaac Sim Docker Remote Streaming Setup Guide

A step-by-step guide for running Isaac Sim via Docker on a remote Linux server and connecting from a local PC using NVIDIA Omniverse Streaming Client.

This guide includes pitfalls and solutions discovered through real-world troubleshooting.

---

## Table of Contents

1. [System Requirements](#1-system-requirements)
2. [Prerequisites](#2-prerequisites)
3. [Get an NGC API Key](#3-get-an-ngc-api-key)
4. [Project File Structure](#4-project-file-structure)
5. [Download and Run Isaac Sim](#5-download-and-run-isaac-sim)
6. [Install and Connect Omniverse Streaming Client](#6-install-and-connect-omniverse-streaming-client)
7. [Remote Access via Tailscale VPN](#7-remote-access-via-tailscale-vpn)
8. [Troubleshooting](#8-troubleshooting)
9. [Isaac Lab Setup](#9-isaac-lab-setup)

---

## 1. System Requirements

### Server (Remote Machine)

| Item | Minimum | Recommended |
|------|---------|-------------|
| GPU | NVIDIA RTX 3080+ | RTX 4090 |
| VRAM | 10 GB | 24 GB |
| RAM | 32 GB | 64 GB+ |
| Free Disk | 50 GB | 100 GB+ |
| OS | Ubuntu 20.04+ | Ubuntu 22.04 |
| NVIDIA Driver | 535+ | Latest |
| CUDA | 12.x | 12.2+ |

### Local PC (Client)

- Windows, Linux, or macOS capable of running NVIDIA Omniverse Streaming Client
- Tailscale or direct network access to the server

---

## 2. Prerequisites

### 2-1. Verify Docker

```bash
docker --version
# Requires Docker 24.0+

docker compose version
# Requires Docker Compose v2.x
```

If Docker is not installed:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2-2. Verify NVIDIA Container Toolkit

```bash
nvidia-smi
# Confirms NVIDIA driver and CUDA version

docker info | grep -i nvidia
# Should output "nvidia" if properly installed
```

If NVIDIA Container Toolkit is missing:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

# Set NVIDIA as the default Docker runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify:

```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
# Success: GPU info is printed inside the container
```

---

## 3. Get an NGC API Key

The Isaac Sim image is hosted on NVIDIA NGC (`nvcr.io`) and requires an API key to pull.

1. Go to [https://ngc.nvidia.com](https://ngc.nvidia.com) → Sign in (free account)
2. Top-right profile icon → **Setup** → **Generate API Key**
3. Click **+ Generate Personal Key**
4. Copy and store the key securely

---

## 4. Project File Structure

### 4-1. Create Directories

```bash
mkdir -p ~/isaac-sim-docker
cd ~/isaac-sim-docker

# Volume directories for cache and data persistence
mkdir -p volumes/cache/{kit,ov,pip,glcache,computecache}
mkdir -p volumes/{logs,workspace}
```

### 4-2. Create `.env`

```bash
cat > .env << 'EOF'
# NGC API Key (https://ngc.nvidia.com/setup/api-key)
NGC_API_KEY=your_ngc_api_key_here

# Isaac Sim version (compatible with Isaac Lab 2.x)
ISAAC_SIM_VERSION=4.5.0

# Data storage path
DATA_DIR=./volumes

# GPU selection (all / 0 / 1 / 0,1)
NVIDIA_VISIBLE_DEVICES=all
EOF
```

Replace `your_ngc_api_key_here` with the actual key from Step 3.

### 4-3. Create `docker-compose.yaml`

> **Important**: The configuration below incorporates several critical findings from troubleshooting.

```bash
cat > docker-compose.yaml << 'EOF'
name: isaac-sim

services:
  isaac-sim:
    image: nvcr.io/nvidia/isaac-sim:${ISAAC_SIM_VERSION:-4.5.0}
    container_name: isaac-sim

    restart: unless-stopped

    # GPU access
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    # ★ CRITICAL: host network mode is required
    # With bridge mode, Isaac Sim generates WebRTC ICE candidates using the
    # internal Docker IP (172.17.0.x), which the client cannot reach.
    # This causes a black screen or connection failure.
    network_mode: host

    environment:
      - ACCEPT_EULA=Y
      - PRIVACY_CONSENT=Y
      - NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-all}
      - NVIDIA_DRIVER_CAPABILITIES=all

    volumes:
      - ${DATA_DIR:-./volumes}/cache/kit:/isaac-sim/kit/cache:rw
      - ${DATA_DIR:-./volumes}/cache/ov:/root/.cache/ov:rw
      - ${DATA_DIR:-./volumes}/cache/pip:/root/.cache/pip:rw
      - ${DATA_DIR:-./volumes}/cache/glcache:/root/.cache/nvidia/GLCache:rw
      - ${DATA_DIR:-./volumes}/cache/computecache:/root/.nv/ComputeCache:rw
      - ${DATA_DIR:-./volumes}/logs:/root/.nvidia-omniverse/logs:rw
      - ${DATA_DIR:-./volumes}/workspace:/root/workspace:rw

    stdin_open: true
    tty: true

    # ★ CRITICAL: Override entrypoint to use old (local) streaming mode
    #
    # New mode (runheadless.webrtc.sh / port 49100):
    #   Loads omni.services.livestream.nvcf which requires NVIDIA Cloud Functions.
    #   This fails in local/private network environments.
    #
    # Old mode (runoldstreaming.sh / port 48010):
    #   Uses omni.kit.livestream.native for direct local connections. No cloud dependency.
    #
    # WARNING: Setting only `command: ["./runoldstreaming.sh"]` does NOT work.
    # The image ENTRYPOINT is `/bin/sh -c /isaac-sim/runheadless.sh`.
    # With the -c flag, the `command:` value becomes $0 (the script name),
    # not an executable. You must override `entrypoint:` directly.
    entrypoint: ["/bin/sh", "/isaac-sim/runoldstreaming.sh"]
    command: []
EOF
```

---

## 5. Download and Run Isaac Sim

### 5-1. Log in to NGC

```bash
source .env
echo $NGC_API_KEY | docker login nvcr.io -u '$oauthtoken' --password-stdin
# Expect: Login Succeeded
```

### 5-2. Pull the Image

```bash
docker pull nvcr.io/nvidia/isaac-sim:4.5.0
# The image is ~20 GB and may take 20–60 minutes depending on your connection.
```

### 5-3. Start the Container

```bash
docker compose up -d
```

### 5-4. Monitor Logs

```bash
docker compose logs -f --tail=100
```

When running correctly, you will see output like:

```
[omni.kit.app] Starting up...
...
[Info] [omni.kit.livestream.native] Streaming server started on port 48010
```

> **Note on first startup**: Shader compilation takes 5–15 minutes. The message
> `Compiling shaders...` in the logs is normal.

### Verify the Port (optional)

```bash
ss -tlnp | grep 48010
# Should show: 0.0.0.0:48010
```

---

## 6. Install and Connect Omniverse Streaming Client

> **Important**: Isaac Sim 4.5.0 native streaming does not support browser-based access.
> You must use the **NVIDIA Omniverse Streaming Client** desktop application.

### 6-1. Install Streaming Client (Local PC)

1. Visit the [NVIDIA Omniverse Download page](https://www.nvidia.com/en-us/omniverse/download/)
2. Download and install **Omniverse Streaming Client**
   - Windows: `.exe` installer
   - Linux: AppImage or package

### 6-2. Connect

1. Open Omniverse Streaming Client
2. Enter the server address: `SERVER_IP:48010`
   - Local network: server's LAN IP (e.g. `192.168.1.100:48010`)
   - Over Tailscale: Tailscale IP (e.g. `100.x.x.x:48010`)
3. Click **Connect**

---

## 7. Remote Access via Tailscale VPN

Tailscale lets you connect to a remote server securely over the internet without port forwarding.

### 7-1. Install Tailscale

**Server (Linux)**:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Follow the printed URL to authenticate
```

**Local PC**:
- Download from [https://tailscale.com/download](https://tailscale.com/download)
- Sign in with the same Tailscale account

### 7-2. Get the Server's Tailscale IP

```bash
# On the server
tailscale ip -4
# Example output: 100.85.14.35
```

### 7-3. Verify Connectivity from Local PC

**Windows PowerShell**:

```powershell
Test-NetConnection -ComputerName 100.85.14.35 -Port 48010
# TcpTestSucceeded: True means the port is reachable
```

**Linux/macOS**:

```bash
nc -zv 100.85.14.35 48010
```

### 7-4. Connect via Omniverse Streaming Client

Use the Tailscale IP:

```
100.85.14.35:48010
```

---

## 8. Troubleshooting

### Issue 1: Black Screen

**Symptom**: Omniverse Streaming Client connects but shows only a black screen.

**Cause**: Docker `bridge` network mode causes Isaac Sim to generate WebRTC ICE candidates with an internal Docker IP (`172.17.0.x`). The client sends packets to this internal address, which cannot be reached from outside the container.

**Fix**: Use `network_mode: host` in `docker-compose.yaml`:

```yaml
network_mode: host
# Remove any `ports:` section — it is ignored with host networking
```

---

### Issue 2: "Unable to initiate a connection"

**Symptom**: TCP connection succeeds, but Omniverse Streaming Client reports connection failure.

**Cause A**: The new WebRTC streaming mode (`runheadless.webrtc.sh`) depends on NVIDIA Cloud Functions (NVCF) infrastructure.

You will see this error repeating in logs:

```
[Error] NVST_CCE_DISCONNECTED when m_connectionCount 0 != 1
```

**Fix**: Switch to old native streaming mode (`runoldstreaming.sh`).

**Cause B**: Port mismatch.
- New WebRTC mode: port **49100**
- Old native mode: port **48010**

Always use port `48010` with `runoldstreaming.sh`.

---

### Issue 3: `command: ["./runoldstreaming.sh"]` Has No Effect

**Cause**: The Isaac Sim image's `ENTRYPOINT` is `/bin/sh -c /isaac-sim/runheadless.sh`.
When a shell is invoked with `-c`, `command:` in docker-compose becomes `$0` (the process name), not an executable command.

**Fix**: Override `entrypoint:` directly instead of `command:`:

```yaml
# ❌ Does NOT work
command: ["./runoldstreaming.sh"]

# ✓ Correct
entrypoint: ["/bin/sh", "/isaac-sim/runoldstreaming.sh"]
command: []
```

---

### Issue 4: ROS2 Bridge Errors (Safe to Ignore)

You may see these messages in logs:

```
[Error] Failed to load plugin 'ROS2 Bridge'
AMENT_PREFIX_PATH not set
```

**Cause**: ROS2 is not installed or configured in the container.

**Impact**: None. This does not affect Isaac Sim simulation or streaming. Safe to ignore.

---

### Issue 5: Slow First Startup

**Cause**: Shader compilation (expected behavior).

- First run: 5–15 minutes
- Subsequent runs: 1–2 minutes (cached)

As long as `volumes/cache/` is preserved, the cache persists across restarts.

---

### Issue 6: GPU Not Recognized in Container

```bash
# Verify GPU access in Docker
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# If this fails, reconfigure NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

---

## 9. Isaac Lab Setup

Isaac Lab is a robot learning framework built on top of Isaac Sim.

### 9-1. Clone Isaac Lab

```bash
git clone https://github.com/isaac-sim/IsaacLab.git ./IsaacLab
```

### 9-2. Configure Docker Environment

```bash
cd IsaacLab

# Create .env from template
cp docker/.env.base docker/.env

# Set NGC API Key
sed -i "s/NGC_API_KEY=.*/NGC_API_KEY=your_key_here/" docker/.env
```

### 9-3. Build the Isaac Lab Docker Image

```bash
# First build includes Isaac Sim base image; may take ~30 minutes
bash docker/container.sh build
```

### 9-4. Start and Enter the Container

```bash
# Start
bash docker/container.sh start

# Enter the container shell
bash docker/container.sh enter

# Run an example (inside the container)
python source/standalone/tutorials/00_sim/create_empty.py
```

---

## Summary: Key Configuration Points

| Item | Correct Setting | Wrong Setting |
|------|----------------|---------------|
| Docker network | `network_mode: host` | `bridge` (default) |
| Streaming script | `runoldstreaming.sh` | `runheadless.webrtc.sh` |
| Streaming port | **48010** | 8899, 49100 |
| Client app | Omniverse Streaming Client | Browser |
| Script override | Use `entrypoint:` | Change `command:` only |

---

## Quick Command Reference

```bash
# 1. Log in to NGC
source .env && echo $NGC_API_KEY | docker login nvcr.io -u '$oauthtoken' --password-stdin

# 2. Pull the image
docker pull nvcr.io/nvidia/isaac-sim:4.5.0

# 3. Start
docker compose up -d

# 4. Monitor logs
docker compose logs -f --tail=100

# 5. Shell into the container
docker exec -it isaac-sim bash

# 6. Stop
docker compose down
```

**Connect**: Omniverse Streaming Client → `SERVER_IP:48010`
