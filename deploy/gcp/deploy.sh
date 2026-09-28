#!/usr/bin/env bash
# GCP VM(Linux) 에서 실행되는 컨테이너 배포 스크립트.
# deploy/deploy.ps1(Windows PC) 과 같은 흐름이다 —
#   이미지 pull → Compose 교체 → 헬스체크 → 실패 시 직전 이미지로 롤백.
#
# 비밀값은 VM 의 env 파일(기본 /srv/haetdeul/.env)에 둔다. 워크플로는
# 이미지 태그(BACKEND_IMAGE · FRONTEND_IMAGE · APP_VERSION)만 넘긴다.
# 셸에 export 된 값이 env 파일보다 우선한다.
#
# 수동 실행:
#   BACKEND_IMAGE=ghcr.io/...-backend:latest FRONTEND_IMAGE=ghcr.io/...-frontend:latest \
#     bash deploy/gcp/deploy.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-/srv/haetdeul/.env}"
PROJECT="${COMPOSE_PROJECT_NAME:-mainproject}"

: "${BACKEND_IMAGE:?BACKEND_IMAGE 환경변수가 설정되지 않았습니다.}"
: "${FRONTEND_IMAGE:?FRONTEND_IMAGE 환경변수가 설정되지 않았습니다.}"
export APP_VERSION="${APP_VERSION:-dev}"
export ML_IMAGE="${ML_IMAGE:-ghcr.io/mpsddd-commits/haetdeul-ml:latest}"
# compose.yml 이 필수로 요구하는 값. GCP 에서는 ML 이 같은 내부망에 있다.
export ML_CONSOLE_ORIGIN="${ML_CONSOLE_ORIGIN:-http://ml-backend:8102}"

[[ -f "$ENV_FILE" ]] || { echo "env 파일이 없습니다: $ENV_FILE" >&2; exit 1; }

compose() {
  docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" \
    -f "$REPO_ROOT/compose.yml" -f "$REPO_ROOT/deploy/gcp/compose.gcp.yml" "$@"
}

step() { printf '\n=== %s ===\n' "$1"; }

container_image() {
  docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || true
}

check_health() {
  for i in $(seq 1 30); do
    sleep 2
    if curl -fsS -o /dev/null http://127.0.0.1:8000/health \
      && compose exec -T frontend wget -q -O /dev/null http://127.0.0.1/ \
      && compose exec -T frontend wget -q -O /dev/null http://127.0.0.1/api/health \
      && compose exec -T ml-backend python -c \
           "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8102/openapi.json')"; then
      return 0
    fi
    echo "  대기 중... ($i/30)"
  done
  return 1
}

step '도커 확인'
docker version --format '{{.Server.Version}}'
docker compose version

step '롤백 대상 기록'
prev_backend="$(container_image mainproject-backend)"
prev_frontend="$(container_image mainproject-frontend)"
prev_ml="$(container_image mainproject-ml-backend)"
echo "직전 Backend : ${prev_backend:-(없음 · 최초 배포)}"
echo "직전 Frontend: ${prev_frontend:-(없음 · 최초 배포)}"
echo "직전 ML      : ${prev_ml:-(없음 · 최초 배포)}"

step '이미지 pull'
docker pull "$BACKEND_IMAGE"
docker pull "$FRONTEND_IMAGE"
docker pull "$ML_IMAGE"

step 'Docker Compose 컨테이너 교체'
export BACKEND_IMAGE FRONTEND_IMAGE
healthy=false
if compose up --detach --force-recreate --remove-orphans && check_health; then
  healthy=true
fi

if [[ "$healthy" != true ]]; then
  echo "헬스체크 실패." >&2
  compose logs --tail 50 || true
  if [[ -n "$prev_backend" && -n "$prev_frontend" ]]; then
    echo "직전 이미지로 롤백합니다." >&2
    export BACKEND_IMAGE="$prev_backend" FRONTEND_IMAGE="$prev_frontend"
    [[ -n "$prev_ml" ]] && export ML_IMAGE="$prev_ml"
    compose up --detach --force-recreate --remove-orphans
    if check_health; then echo "롤백 완료." >&2; else echo "롤백 후에도 헬스체크 실패." >&2; fi
  else
    echo "직전 이미지가 없어 컨테이너를 내립니다." >&2
    compose down
  fi
  exit 1
fi

echo "배포 성공."
docker ps --filter "name=^mainproject-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

step '사용하지 않는 이미지 정리'
docker image prune --force >/dev/null
