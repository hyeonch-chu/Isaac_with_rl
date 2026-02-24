#!/usr/bin/env bash
# ============================================================
# Isaac Sim Docker 원격 스트리밍 환경 자동 설정 스크립트
# Isaac Sim Docker Remote Streaming Auto-Setup Script
#
# 사용법 / Usage:
#   bash setup.sh
#
# 이 스크립트는 다음을 자동으로 수행합니다:
# This script automatically performs:
#   1. 사전 요건 확인 (Docker, NVIDIA Container Toolkit, GPU)
#      Prerequisite checks (Docker, NVIDIA Container Toolkit, GPU)
#   2. NGC API Key 설정 및 로그인
#      NGC API Key configuration and login
#   3. 프로젝트 파일 생성 (.env, docker-compose.yaml)
#      Project file generation (.env, docker-compose.yaml)
#   4. 볼륨 디렉토리 생성
#      Volume directory creation
#   5. Isaac Sim 이미지 다운로드
#      Isaac Sim image pull
#   6. 컨테이너 시작 및 접속 정보 출력
#      Container startup and connection info display
# ============================================================
set -euo pipefail

# ── 색상 정의 ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; }

# ── 설정값 ─────────────────────────────────────────────────
ISAAC_SIM_VERSION="${ISAAC_SIM_VERSION:-4.5.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 헬퍼 함수 ──────────────────────────────────────────────

check_command() {
    if command -v "$1" &>/dev/null; then
        success "$1 설치됨 ($(command -v "$1"))"
        return 0
    else
        fail "$1 설치되지 않음"
        return 1
    fi
}

# ── 배너 ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        Isaac Sim Docker 원격 스트리밍 환경 설정              ║${NC}"
echo -e "${BOLD}║        Isaac Sim Docker Remote Streaming Setup               ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ══════════════════════════════════════════════════════════════
# 단계 1: 사전 요건 확인
# ══════════════════════════════════════════════════════════════

step "1/6  사전 요건 확인 (Prerequisites)"

PREREQ_OK=true

# Docker 확인
if check_command docker; then
    DOCKER_VER=$(docker --version | grep -oP '\d+\.\d+' | head -1)
    info "Docker version: $DOCKER_VER"
else
    error "Docker를 먼저 설치하세요: curl -fsSL https://get.docker.com | sh"
    PREREQ_OK=false
fi

# Docker Compose 확인
if docker compose version &>/dev/null; then
    success "Docker Compose v2 사용 가능"
else
    fail "Docker Compose v2가 필요합니다"
    PREREQ_OK=false
fi

# 현재 사용자가 docker 그룹에 속하는지 확인
if groups | grep -qw docker; then
    success "현재 사용자가 docker 그룹에 속함"
else
    warn "현재 사용자가 docker 그룹에 속하지 않습니다."
    warn "다음 명령 실행 후 재로그인: sudo usermod -aG docker \$USER"
fi

# nvidia-smi 확인
if check_command nvidia-smi; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "N/A")
    info "GPU 정보:"
    while IFS= read -r line; do
        info "  $line"
    done <<< "$GPU_INFO"
else
    error "NVIDIA 드라이버가 설치되지 않았습니다."
    PREREQ_OK=false
fi

# NVIDIA Container Toolkit 확인
if docker info 2>/dev/null | grep -qi "nvidia"; then
    success "NVIDIA Container Toolkit 설정됨"
elif command -v nvidia-ctk &>/dev/null; then
    warn "NVIDIA Container Toolkit이 설치되어 있으나 Docker 런타임이 설정되지 않았습니다."
    warn "다음 명령을 실행하세요:"
    warn "  sudo nvidia-ctk runtime configure --runtime=docker"
    warn "  sudo systemctl restart docker"
else
    error "NVIDIA Container Toolkit이 설치되지 않았습니다."
    error "설치 방법은 tutorial.md 또는 tutorial_kor.md를 참조하세요."
    PREREQ_OK=false
fi

# git 확인 (Isaac Lab 선택 설치 시 필요)
check_command git || warn "git이 없으면 Isaac Lab을 설치할 수 없습니다 (Isaac Sim 단독 사용 시 불필요)"

if [ "$PREREQ_OK" = false ]; then
    echo ""
    error "사전 요건이 충족되지 않았습니다. 위 오류를 해결한 후 다시 실행하세요."
    exit 1
fi

# GPU Docker 테스트
info "GPU Docker 접근 테스트 중..."
if docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi -L &>/dev/null; then
    success "GPU Docker 접근 확인됨"
else
    warn "GPU Docker 접근 테스트 실패. NVIDIA Container Toolkit 설정을 확인하세요."
fi

# ══════════════════════════════════════════════════════════════
# 단계 2: NGC API Key 설정
# ══════════════════════════════════════════════════════════════

step "2/6  NGC API Key 설정"

ENV_FILE="$SCRIPT_DIR/.env"

# 기존 .env에서 NGC_API_KEY 로드
NGC_API_KEY=""
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    NGC_API_KEY=$(grep "^NGC_API_KEY=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi

# 키가 없거나 플레이스홀더인 경우 입력 요청
if [ -z "$NGC_API_KEY" ] || [ "$NGC_API_KEY" = "your_ngc_api_key_here" ]; then
    echo ""
    info "NGC API Key가 필요합니다."
    info "발급 URL: https://ngc.nvidia.com/setup/api-key"
    echo ""
    while true; do
        read -rp "NGC API Key를 입력하세요: " NGC_API_KEY
        if [ -n "$NGC_API_KEY" ] && [ "$NGC_API_KEY" != "your_ngc_api_key_here" ]; then
            break
        fi
        warn "올바른 API Key를 입력하세요."
    done
else
    # 키 일부 마스킹하여 표시
    MASKED_KEY="${NGC_API_KEY:0:8}...${NGC_API_KEY: -4}"
    success "NGC API Key 로드됨: $MASKED_KEY"
fi

# ══════════════════════════════════════════════════════════════
# 단계 3: 프로젝트 파일 생성
# ══════════════════════════════════════════════════════════════

step "3/6  프로젝트 파일 생성"

# ── .env 생성 ──
if [ -f "$ENV_FILE" ]; then
    # 기존 파일 업데이트
    if grep -q "^NGC_API_KEY=" "$ENV_FILE"; then
        sed -i "s|^NGC_API_KEY=.*|NGC_API_KEY=$NGC_API_KEY|" "$ENV_FILE"
    else
        echo "NGC_API_KEY=$NGC_API_KEY" >> "$ENV_FILE"
    fi
    success ".env 업데이트됨"
else
    # 새 파일 생성
    cat > "$ENV_FILE" << EOF
# ============================================================
# Isaac Sim / Isaac Lab Docker 환경 설정
# ============================================================

# NGC API Key (https://ngc.nvidia.com/setup/api-key)
NGC_API_KEY=$NGC_API_KEY

# Isaac Sim 버전 (Isaac Lab 2.x 호환)
ISAAC_SIM_VERSION=$ISAAC_SIM_VERSION

# 데이터 저장 디렉토리
DATA_DIR=./volumes

# GPU 설정 (all / 0 / 1 / 0,1)
NVIDIA_VISIBLE_DEVICES=all
EOF
    success ".env 생성됨"
fi

# ── docker-compose.yaml 생성 ──
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

if [ -f "$COMPOSE_FILE" ]; then
    info "docker-compose.yaml이 이미 존재합니다. 유지합니다."
else
    cat > "$COMPOSE_FILE" << 'EOF'
name: isaac-sim

services:
  isaac-sim:
    image: nvcr.io/nvidia/isaac-sim:${ISAAC_SIM_VERSION:-4.5.0}
    container_name: isaac-sim

    restart: unless-stopped

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    # CRITICAL: host network mode required for WebRTC ICE candidates to use real server IP
    # With bridge mode, ICE candidates use internal Docker IP (172.17.0.x) -> black screen
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

    # CRITICAL: Override entrypoint to use old streaming mode (port 48010)
    # New mode (runheadless.webrtc.sh) requires NVIDIA Cloud Functions -> fails locally
    # Note: `command:` alone does NOT work because the image ENTRYPOINT uses /bin/sh -c
    entrypoint: ["/bin/sh", "/isaac-sim/runoldstreaming.sh"]
    command: []
EOF
    success "docker-compose.yaml 생성됨"
fi

# ══════════════════════════════════════════════════════════════
# 단계 4: 볼륨 디렉토리 생성
# ══════════════════════════════════════════════════════════════

step "4/6  볼륨 디렉토리 생성"

mkdir -p "$SCRIPT_DIR/volumes/cache"/{kit,ov,pip,glcache,computecache}
mkdir -p "$SCRIPT_DIR/volumes"/{logs,workspace}
success "볼륨 디렉토리 생성 완료: $SCRIPT_DIR/volumes/"

# ══════════════════════════════════════════════════════════════
# 단계 5: NGC 로그인 및 이미지 다운로드
# ══════════════════════════════════════════════════════════════

step "5/6  NGC 로그인 및 Isaac Sim 이미지 다운로드"

info "NGC 레지스트리 로그인 중..."
if echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin 2>&1 | grep -q "Succeeded"; then
    success "NGC 로그인 성공"
else
    error "NGC 로그인 실패. API Key를 확인하세요."
    exit 1
fi

IMAGE="nvcr.io/nvidia/isaac-sim:${ISAAC_SIM_VERSION}"

# 이미 다운로드되어 있는지 확인
if docker image inspect "$IMAGE" &>/dev/null; then
    success "이미지가 이미 존재합니다: $IMAGE"
else
    echo ""
    info "Isaac Sim ${ISAAC_SIM_VERSION} 이미지 다운로드 중..."
    info "이미지 크기: 약 20GB (네트워크 속도에 따라 20~60분 소요)"
    echo ""
    docker pull "$IMAGE"
    success "이미지 다운로드 완료"
fi

# ══════════════════════════════════════════════════════════════
# 단계 6: 컨테이너 시작
# ══════════════════════════════════════════════════════════════

step "6/6  Isaac Sim 컨테이너 시작"

cd "$SCRIPT_DIR"

# 기존 컨테이너 정리
if docker ps -a --format '{{.Names}}' | grep -q "^isaac-sim$"; then
    warn "기존 isaac-sim 컨테이너를 정리합니다..."
    docker compose down 2>/dev/null || true
fi

info "컨테이너 시작 중..."
docker compose up -d

# 잠시 대기 후 컨테이너 상태 확인
sleep 3
if docker ps --format '{{.Names}}' | grep -q "^isaac-sim$"; then
    success "컨테이너 시작됨"
else
    error "컨테이너 시작에 실패했습니다."
    error "로그 확인: docker compose logs --tail=50"
    exit 1
fi

# 서버 IP 수집
SERVER_IP=$(hostname -I | awk '{print $1}')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

# ══════════════════════════════════════════════════════════════
# 완료
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                   설정 완료! Setup Complete!                 ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}접속 방법 (Connection Info):${NC}"
echo ""
echo -e "  ${BOLD}클라이언트 앱${NC}: NVIDIA Omniverse Streaming Client"
echo -e "  ${BOLD}스트리밍 포트${NC}: 48010 (native streaming mode)"
echo ""
echo -e "  ${BOLD}접속 주소:${NC}"
echo -e "    LAN:       ${GREEN}${SERVER_IP}:48010${NC}"
if [ -n "$TAILSCALE_IP" ]; then
echo -e "    Tailscale: ${GREEN}${TAILSCALE_IP}:48010${NC}"
fi
echo ""
echo -e "${BOLD}주의사항:${NC}"
echo -e "  • 첫 실행 시 셰이더 컴파일로 5~15분 소요됩니다"
echo -e "  • 로그 확인: ${YELLOW}docker compose logs -f --tail=100${NC}"
echo -e "  • 컨테이너 접속: ${YELLOW}docker exec -it isaac-sim bash${NC}"
echo -e "  • 중지: ${YELLOW}docker compose down${NC}"
echo ""
echo -e "${BOLD}자세한 내용은 tutorial_kor.md 또는 tutorial.md를 참조하세요.${NC}"
echo ""

info "현재 로그를 보려면 Ctrl+C로 중단하고 다음을 실행:"
info "  docker compose logs -f --tail=100"
