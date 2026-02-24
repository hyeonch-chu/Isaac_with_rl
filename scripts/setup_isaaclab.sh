#!/usr/bin/env bash
# ============================================================
# Isaac Lab Docker 환경 설정 스크립트
# Isaac Lab 저장소를 클론하고 Docker 컨테이너를 구성합니다.
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ISAACLAB_DIR="$ROOT_DIR/IsaacLab"

# .env 로드
if [ -f "$ROOT_DIR/.env" ]; then
    source "$ROOT_DIR/.env"
fi

echo "================================================================"
echo "  Isaac Lab Docker 설정"
echo "================================================================"
echo ""

# ── 1. 사전 요건 확인 ────────────────────────────────────────

echo "[1/5] 사전 요건 확인..."

if ! command -v docker &>/dev/null; then
    echo "  ERROR: Docker가 설치되어 있지 않습니다."
    exit 1
fi

if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "  WARNING: NVIDIA Docker 런타임이 설정되지 않았을 수 있습니다."
fi

if ! command -v git &>/dev/null; then
    echo "  ERROR: git이 설치되어 있지 않습니다."
    exit 1
fi

echo "  OK: 사전 요건 충족"

# ── 2. Isaac Lab 저장소 클론 ─────────────────────────────────

echo "[2/5] Isaac Lab 저장소 클론..."

if [ -d "$ISAACLAB_DIR" ]; then
    echo "  이미 존재함: $ISAACLAB_DIR"
    echo "  최신 변경사항 가져오기..."
    git -C "$ISAACLAB_DIR" pull
else
    git clone https://github.com/isaac-sim/IsaacLab.git "$ISAACLAB_DIR"
    echo "  OK: 클론 완료 → $ISAACLAB_DIR"
fi

# ── 3. NGC 로그인 확인 ───────────────────────────────────────

echo "[3/5] NGC Docker 레지스트리 로그인..."

if [ -z "$NGC_API_KEY" ] || [ "$NGC_API_KEY" = "your_ngc_api_key_here" ]; then
    echo ""
    echo "  NGC_API_KEY가 설정되지 않았습니다."
    echo "  발급 URL: https://ngc.nvidia.com/setup/api-key"
    echo ""
    read -rp "  NGC API Key를 입력하세요: " NGC_API_KEY
    # .env 업데이트
    sed -i "s/NGC_API_KEY=.*/NGC_API_KEY=$NGC_API_KEY/" "$ROOT_DIR/.env"
fi

echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
echo "  OK: NGC 로그인 완료"

# ── 4. Isaac Lab Docker 환경 파일 설정 ───────────────────────

echo "[4/5] Isaac Lab Docker 환경 설정..."

ISAACLAB_DOCKER_DIR="$ISAACLAB_DIR/docker"

# Isaac Lab의 .env.base를 .env로 복사 (없으면 스킵)
if [ -f "$ISAACLAB_DOCKER_DIR/.env.base" ] && [ ! -f "$ISAACLAB_DOCKER_DIR/.env" ]; then
    cp "$ISAACLAB_DOCKER_DIR/.env.base" "$ISAACLAB_DOCKER_DIR/.env"
    echo "  OK: $ISAACLAB_DOCKER_DIR/.env 생성됨"
fi

# Isaac Lab docker/.env에 NGC API Key 설정
if [ -f "$ISAACLAB_DOCKER_DIR/.env" ]; then
    if grep -q "NGC_API_KEY" "$ISAACLAB_DOCKER_DIR/.env"; then
        sed -i "s/NGC_API_KEY=.*/NGC_API_KEY=$NGC_API_KEY/" "$ISAACLAB_DOCKER_DIR/.env"
    else
        echo "NGC_API_KEY=$NGC_API_KEY" >> "$ISAACLAB_DOCKER_DIR/.env"
    fi
    echo "  OK: NGC_API_KEY 설정됨"
fi

# ── 5. Isaac Lab Docker 이미지 빌드 ──────────────────────────

echo "[5/5] Isaac Lab Docker 이미지 빌드..."
echo "  (처음 실행 시 Isaac Sim 이미지 다운로드 포함 30분 이상 소요될 수 있습니다)"
echo ""

cd "$ISAACLAB_DIR"

# Isaac Lab container.sh 스크립트 사용
if [ -f "./docker/container.sh" ]; then
    bash ./docker/container.sh build
else
    echo "  WARNING: container.sh를 찾을 수 없습니다."
    echo "  수동으로 빌드하세요: cd $ISAACLAB_DIR && docker compose -f docker/docker-compose.yaml build"
fi

# ── 완료 ─────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "  Isaac Lab 설정 완료!"
echo "================================================================"
echo ""
echo "  다음 명령어로 Isaac Lab을 실행하세요:"
echo ""
echo "    cd $ISAACLAB_DIR"
echo ""
echo "  컨테이너 시작:"
echo "    bash docker/container.sh start"
echo ""
echo "  컨테이너 접속:"
echo "    bash docker/container.sh enter"
echo ""
echo "  Isaac Lab 예제 실행 (컨테이너 내부에서):"
echo "    python source/standalone/tutorials/00_sim/create_empty.py"
echo ""
echo "  WebRTC 스트리밍으로 시각화하려면:"
echo "    bash docker/container.sh start --streaming"
echo "  접속: http://$(hostname -I | awk '{print $1}'):8899"
echo ""
