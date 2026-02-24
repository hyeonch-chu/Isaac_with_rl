# Isaac Sim Docker 원격 스트리밍 설정 가이드 (한국어)

원격 리눅스 서버에서 Isaac Sim을 Docker로 실행하고, 로컬 PC에서 NVIDIA Omniverse Streaming Client로 접속하는 방법을 단계별로 설명합니다.

이 가이드는 실제 설정 과정에서 마주친 함정들과 해결책을 포함하고 있습니다.

---

## 목차

1. [시스템 요구사항](#1-시스템-요구사항)
2. [사전 준비](#2-사전-준비)
3. [NGC API Key 발급](#3-ngc-api-key-발급)
4. [프로젝트 파일 구성](#4-프로젝트-파일-구성)
5. [Isaac Sim 이미지 다운로드 및 실행](#5-isaac-sim-이미지-다운로드-및-실행)
6. [Omniverse Streaming Client 설치 및 접속](#6-omniverse-streaming-client-설치-및-접속)
7. [Tailscale VPN을 통한 원격 접속](#7-tailscale-vpn을-통한-원격-접속)
8. [자주 발생하는 문제 및 해결책](#8-자주-발생하는-문제-및-해결책)
9. [Isaac Lab 설정](#9-isaac-lab-설정)

---

## 1. 시스템 요구사항

### 서버 (원격 머신)

| 항목 | 최소 사양 | 권장 사양 |
|------|-----------|-----------|
| GPU | NVIDIA RTX 3080+ | RTX 4090 |
| VRAM | 10GB | 24GB |
| RAM | 32GB | 64GB+ |
| 디스크 여유공간 | 50GB | 100GB+ |
| OS | Ubuntu 20.04+ | Ubuntu 22.04 |
| NVIDIA Driver | 535+ | 최신 |
| CUDA | 12.x | 12.2+ |

### 로컬 PC (클라이언트)

- NVIDIA Omniverse Streaming Client 설치 가능한 Windows/Linux/macOS
- Tailscale 또는 서버와 직접 네트워크 연결

---

## 2. 사전 준비

### 2-1. Docker 설치 확인

```bash
docker --version
# Docker version 24.0+ 필요

docker compose version
# Docker Compose v2.x 필요
```

Docker가 없다면:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2-2. NVIDIA Container Toolkit 설치 확인

```bash
nvidia-smi
# Driver Version과 CUDA Version 확인

docker info | grep -i nvidia
# "nvidia" 출력되면 설치됨
```

NVIDIA Container Toolkit이 없다면:

```bash
# NVIDIA Container Toolkit 설치
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

# Docker가 NVIDIA 런타임을 기본으로 사용하도록 설정
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

설치 후 확인:

```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
# GPU 정보가 출력되면 성공
```

---

## 3. NGC API Key 발급

Isaac Sim 이미지는 NVIDIA NGC 레지스트리(`nvcr.io`)에서 호스팅되며, 다운로드에 API Key가 필요합니다.

1. [https://ngc.nvidia.com](https://ngc.nvidia.com) 접속 → 로그인 (무료 계정)
2. 우측 상단 프로필 아이콘 → **Setup** → **Generate API Key**
3. **+ Generate Personal Key** 클릭
4. 생성된 키를 안전한 곳에 복사해 둠

---

## 4. 프로젝트 파일 구성

### 4-1. 디렉토리 생성

```bash
mkdir -p ~/isaac-sim-docker
cd ~/isaac-sim-docker

# 볼륨 디렉토리 (캐시 및 데이터 영속성)
mkdir -p volumes/cache/{kit,ov,pip,glcache,computecache}
mkdir -p volumes/{logs,workspace}
```

### 4-2. `.env` 파일 생성

```bash
cat > .env << 'EOF'
# NGC API Key (https://ngc.nvidia.com/setup/api-key)
NGC_API_KEY=your_ngc_api_key_here

# Isaac Sim 버전 (Isaac Lab 2.x 호환)
ISAAC_SIM_VERSION=4.5.0

# 데이터 저장 경로
DATA_DIR=./volumes

# GPU 설정 (all / 0 / 1 / 0,1)
NVIDIA_VISIBLE_DEVICES=all
EOF
```

`your_ngc_api_key_here`를 3단계에서 발급받은 실제 키로 교체합니다.

### 4-3. `docker-compose.yaml` 생성

> **중요**: 아래 설정에는 시행착오를 통해 발견한 핵심 포인트들이 포함되어 있습니다.

```bash
cat > docker-compose.yaml << 'EOF'
name: isaac-sim

services:
  isaac-sim:
    image: nvcr.io/nvidia/isaac-sim:${ISAAC_SIM_VERSION:-4.5.0}
    container_name: isaac-sim

    restart: unless-stopped

    # GPU 접근 설정
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    # ★ 핵심: host 네트워크 모드 필수
    # bridge 모드를 사용하면 WebRTC ICE 후보가 내부 Docker IP(172.17.0.x)로 생성되어
    # 클라이언트가 서버에 연결할 수 없음 → 검은 화면 또는 연결 실패
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

    # ★ 핵심: entrypoint 오버라이드로 구 스트리밍 모드 사용
    # - 신규 모드(runheadless.webrtc.sh): NVIDIA Cloud Functions(NVCF) 클라우드 인프라 필요
    #   → 로컬/사설 네트워크 환경에서 연결 불가
    # - 구 모드(runoldstreaming.sh): 로컬 직접 연결, 포트 48010
    #
    # 주의: command: ["./runoldstreaming.sh"] 처럼 command만 바꾸면 작동하지 않음
    # 이미지 ENTRYPOINT가 /bin/sh -c 이므로 command는 $0(스크립트명)이 될 뿐임
    # → entrypoint를 직접 오버라이드해야 함
    entrypoint: ["/bin/sh", "/isaac-sim/runoldstreaming.sh"]
    command: []
EOF
```

---

## 5. Isaac Sim 이미지 다운로드 및 실행

### 5-1. NGC 로그인

```bash
source .env
echo $NGC_API_KEY | docker login nvcr.io -u '$oauthtoken' --password-stdin
# Login Succeeded 출력 확인
```

### 5-2. 이미지 다운로드

```bash
docker pull nvcr.io/nvidia/isaac-sim:4.5.0
# ※ 이미지 크기 약 20GB, 네트워크 속도에 따라 수십 분 소요
```

### 5-3. 컨테이너 실행

```bash
docker compose up -d
```

### 5-4. 로그 확인

```bash
docker compose logs -f --tail=100
```

정상 실행 시 아래와 같은 로그가 출력됩니다:

```
[omni.kit.app] Starting up...
...
[Info] [omni.kit.livestream.native] Streaming server started on port 48010
```

> **첫 실행 시 주의**: 셰이더 컴파일로 인해 5~15분 정도 소요됩니다. 로그에
> `Compiling shaders...` 메시지가 뜨는 것은 정상입니다.

### 포트 확인 (선택)

```bash
ss -tlnp | grep 48010
# 0.0.0.0:48010 이 표시되면 정상
```

---

## 6. Omniverse Streaming Client 설치 및 접속

> **주의**: Isaac Sim 4.5.0의 native streaming 모드는 브라우저 접속을 지원하지 않습니다.
> 반드시 **NVIDIA Omniverse Streaming Client** 데스크탑 앱을 사용해야 합니다.

### 6-1. Streaming Client 설치 (로컬 PC)

1. [NVIDIA Omniverse 다운로드 페이지](https://www.nvidia.com/en-us/omniverse/download/) 접속
2. **Omniverse Streaming Client** 설치
   - Windows: `.exe` 설치 파일
   - Linux: AppImage 또는 패키지

### 6-2. 접속

1. Omniverse Streaming Client 실행
2. 서버 주소 입력: `SERVER_IP:48010`
   - 로컬 네트워크: 서버의 실제 IP (예: `192.168.1.100:48010`)
   - Tailscale 사용 시: Tailscale IP (예: `100.x.x.x:48010`)
3. Connect 클릭

---

## 7. Tailscale VPN을 통한 원격 접속

인터넷을 통해 서버에 접속할 때 Tailscale을 사용하면 포트포워딩 없이 안전하게 연결할 수 있습니다.

### 7-1. Tailscale 설치

**서버 (리눅스)**:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# 출력되는 URL로 인증 완료
```

**로컬 PC**:
- [https://tailscale.com/download](https://tailscale.com/download) 에서 설치
- 동일한 Tailscale 계정으로 로그인

### 7-2. Tailscale IP 확인

```bash
# 서버에서
tailscale ip -4
# 예: 100.85.14.35
```

### 7-3. 연결 확인 (로컬 PC에서)

**Windows PowerShell**:

```powershell
Test-NetConnection -ComputerName 100.85.14.35 -Port 48010
# TcpTestSucceeded: True 이면 연결 가능
```

**Linux/macOS**:

```bash
nc -zv 100.85.14.35 48010
```

### 7-4. Omniverse Streaming Client로 접속

Tailscale IP로 접속:

```
100.85.14.35:48010
```

---

## 8. 자주 발생하는 문제 및 해결책

### 문제 1: 검은 화면 (Black Screen)

**증상**: Omniverse Streaming Client에서 연결은 되지만 화면이 검게 나옴.

**원인**: Docker `bridge` 네트워크 모드 사용 시 WebRTC ICE 후보가 내부 Docker IP(`172.17.0.x`)로 생성됨. 클라이언트가 이 내부 IP로 패킷을 보내도 도달하지 못함.

**해결**:

`docker-compose.yaml`에서:
```yaml
network_mode: host  # ← 이것을 사용
# ports: ...        # ← host 모드에서는 ports 설정 불필요 (무시됨)
```

---

### 문제 2: "Unable to initiate a connection" 오류

**증상**: TCP 연결은 성공하지만 Omniverse Streaming Client에서 연결 실패 메시지.

**원인 A**: 신규 WebRTC 모드(`runheadless.webrtc.sh`)의 NVCF 클라우드 의존성.

로그에서 아래 메시지가 반복적으로 나타남:
```
[Error] NVST_CCE_DISCONNECTED when m_connectionCount 0 != 1
```

**해결**: 구 스트리밍 모드(`runoldstreaming.sh`) 사용.

**원인 B**: 포트 불일치.
- 신규 WebRTC 모드: 포트 **49100**
- 구 native 모드: 포트 **48010**

---

### 문제 3: `command: ["./runoldstreaming.sh"]`로 바꿨는데 효과 없음

**원인**: Isaac Sim 이미지의 `ENTRYPOINT`가 `/bin/sh -c /isaac-sim/runheadless.sh` 형태임.
`-c` 플래그를 사용하는 shell에서 `command:`의 값은 `$0`(스크립트 이름)이 되어 실제로 실행되지 않음.

**해결**: `command:`가 아닌 `entrypoint:` 자체를 오버라이드:

```yaml
# ❌ 작동 안 함
command: ["./runoldstreaming.sh"]

# ✓ 올바른 방법
entrypoint: ["/bin/sh", "/isaac-sim/runoldstreaming.sh"]
command: []
```

---

### 문제 4: ROS2 Bridge 오류 (무시 가능)

로그에서 아래 메시지가 나타날 수 있음:

```
[Error] Failed to load plugin 'ROS2 Bridge'
AMENT_PREFIX_PATH not set
```

**원인**: 컨테이너 내에 ROS2가 설치/설정되지 않음.

**영향 없음**: Isaac Sim 실행 및 스트리밍에 영향을 주지 않습니다. 무시해도 됩니다.

---

### 문제 5: 첫 실행 시 너무 오래 걸림

**원인**: 셰이더 컴파일 (정상 동작).

- 처음에는 5~15분 소요
- 두 번째 실행부터는 캐시 덕분에 1~2분으로 단축

`volumes/cache/` 디렉토리를 삭제하지 않으면 캐시가 유지됩니다.

---

### 문제 6: GPU가 인식되지 않음

```bash
# 확인
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# 오류 시 NVIDIA Container Toolkit 재설정
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

---

## 9. Isaac Lab 설정

Isaac Lab은 Isaac Sim 위에서 동작하는 로봇 학습 프레임워크입니다.

### 9-1. Isaac Lab 클론

```bash
git clone https://github.com/isaac-sim/IsaacLab.git ./IsaacLab
```

### 9-2. Isaac Lab Docker 환경 설정

```bash
cd IsaacLab

# .env 파일 생성
cp docker/.env.base docker/.env

# NGC API Key 설정
sed -i "s/NGC_API_KEY=.*/NGC_API_KEY=your_key_here/" docker/.env
```

### 9-3. Isaac Lab Docker 이미지 빌드

```bash
# 처음에는 Isaac Sim 이미지 포함 약 30분 소요
bash docker/container.sh build
```

### 9-4. 컨테이너 시작 및 접속

```bash
# 시작
bash docker/container.sh start

# 컨테이너 내부 접속
bash docker/container.sh enter

# 예제 실행 (컨테이너 내부)
python source/standalone/tutorials/00_sim/create_empty.py
```

---

## 요약: 핵심 포인트

| 항목 | 올바른 설정 | 잘못된 설정 |
|------|-------------|-------------|
| Docker 네트워크 | `network_mode: host` | `bridge` (기본값) |
| 스트리밍 스크립트 | `runoldstreaming.sh` | `runheadless.webrtc.sh` |
| 스트리밍 포트 | **48010** | 8899, 49100 |
| 클라이언트 | Omniverse Streaming Client | 브라우저 |
| Entrypoint 오버라이드 | `entrypoint:` 사용 | `command:` 만 변경 |

---

## 빠른 시작 명령어 요약

```bash
# 1. NGC 로그인
source .env && echo $NGC_API_KEY | docker login nvcr.io -u '$oauthtoken' --password-stdin

# 2. 이미지 다운로드
docker pull nvcr.io/nvidia/isaac-sim:4.5.0

# 3. 시작
docker compose up -d

# 4. 로그 모니터링
docker compose logs -f --tail=100

# 5. 컨테이너 내부 접속
docker exec -it isaac-sim bash

# 6. 중지
docker compose down
```

접속 주소: Omniverse Streaming Client → `SERVER_IP:48010`
