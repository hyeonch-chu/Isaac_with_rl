.PHONY: help setup pull start stop restart logs shell status clean isaaclab-setup

# 서버 IP (상태 출력용)
SERVER_IP := $(shell hostname -I | awk '{print $$1}')

help:
	@echo "================================================================"
	@echo "  Isaac Sim / Isaac Lab Docker 관리 명령어"
	@echo "================================================================"
	@echo ""
	@echo "  초기 설정"
	@echo "  ---------"
	@echo "  make setup          .env 설정 안내 및 디렉토리 생성"
	@echo "  make ngc-login      NGC Docker 레지스트리 로그인"
	@echo "  make pull           Isaac Sim 이미지 다운로드 (약 20GB)"
	@echo ""
	@echo "  Isaac Sim (WebRTC 스트리밍)"
	@echo "  ----------------------------"
	@echo "  make start          Isaac Sim 시작 (백그라운드)"
	@echo "  make stop           Isaac Sim 중지"
	@echo "  make restart        재시작"
	@echo "  make logs           실시간 로그 확인"
	@echo "  make shell          컨테이너 bash 접속"
	@echo "  make status         컨테이너 상태 확인"
	@echo ""
	@echo "  Isaac Lab"
	@echo "  ---------"
	@echo "  make isaaclab-setup Isaac Lab 저장소 클론 및 Docker 설정"
	@echo ""
	@echo "  기타"
	@echo "  ----"
	@echo "  make clean          캐시 및 볼륨 삭제 (주의!)"
	@echo ""

# ── 초기 설정 ──────────────────────────────────────────────

setup:
	@echo "[1/3] 환경 파일 확인..."
	@if grep -q "your_ngc_api_key_here" .env; then \
		echo ""; \
		echo "  !! .env 파일에서 NGC_API_KEY를 설정하세요:"; \
		echo "     https://ngc.nvidia.com/setup/api-key"; \
		echo ""; \
	else \
		echo "  OK: NGC_API_KEY 설정됨"; \
	fi
	@echo "[2/3] 볼륨 디렉토리 생성..."
	@mkdir -p volumes/cache/{kit,ov,pip,glcache,computecache}
	@mkdir -p volumes/{logs,workspace}
	@echo "  OK: 디렉토리 생성 완료"
	@echo "[3/3] GPU 상태 확인..."
	@nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | \
		awk '{print "  GPU: " $$0}'
	@echo ""
	@echo "설정 완료. 다음 단계:"
	@echo "  1. .env 파일에서 NGC_API_KEY 입력"
	@echo "  2. make ngc-login"
	@echo "  3. make pull"
	@echo "  4. make start"

ngc-login:
	@echo "NGC Docker 레지스트리 로그인..."
	@. ./.env && echo $$NGC_API_KEY | docker login nvcr.io -u '$$oauthtoken' --password-stdin

pull:
	@. ./.env && docker pull nvcr.io/nvidia/isaac-sim:$${ISAAC_SIM_VERSION:-4.5.0}

# ── Isaac Sim 관리 ─────────────────────────────────────────

start:
	@mkdir -p volumes/cache/{kit,ov,pip,glcache,computecache} volumes/{logs,workspace}
	@docker compose up -d
	@echo ""
	@echo "Isaac Sim 시작됨"
	@echo "  스트리밍 UI: http://$(SERVER_IP):8899"
	@echo "  로그 확인:   make logs"
	@echo ""
	@echo "  주의: 첫 실행 시 셰이더 컴파일로 5~10분 소요됩니다."

stop:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f --tail=100

shell:
	docker exec -it isaac-sim bash

status:
	@echo "=== 컨테이너 상태 ==="
	@docker compose ps
	@echo ""
	@echo "=== GPU 상태 ==="
	@nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
		--format=csv,noheader | awk '{print "  " $$0}'
	@echo ""
	@echo "  스트리밍 주소: http://$(SERVER_IP):8899"

# ── Isaac Lab 설정 ─────────────────────────────────────────

isaaclab-setup:
	@bash scripts/setup_isaaclab.sh

# ── 정리 ───────────────────────────────────────────────────

clean:
	@echo "경고: 모든 캐시와 로그가 삭제됩니다."
	@read -p "계속하려면 'yes' 입력: " confirm && [ "$$confirm" = "yes" ]
	docker compose down -v
	rm -rf volumes/cache volumes/logs
	@echo "정리 완료 (workspace는 유지됨)"
