#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/A01723266/SpringAI.git}"
REPO_DIR="${REPO_DIR:-SpringAI}"
APP_DIR="${APP_DIR:-spring-ai-chat-demo}"
BRANCH="${BRANCH:-main}"
APP_NAME="${APP_NAME:-spring-ai-chat-demo}"
APP_IMAGE="${APP_IMAGE:-spring-ai-chat-demo:local}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:1b}"
VM_USER="${VM_USER:-opc}"
SSH_KEY="${SSH_KEY:-}"
APP_PORT="${APP_PORT:-8080}"
OLLAMA_VOLUME="${OLLAMA_VOLUME:-ollama}"
NETWORK_NAME="${NETWORK_NAME:-spring-ai-demo-net}"

step() {
  printf '[vm-git-deploy] %s\n' "$1"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Command '%s' was not found.\n" "$1" >&2
    exit 1
  fi
}

ask() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local value

  if [[ -n "${!var_name:-}" ]]; then
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    read -r -p "${prompt}: " value
  fi

  if [[ -z "$value" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

need ssh

ask VM_HOST "Public IP or DNS of the VM"
ask VM_USER "SSH user" "$VM_USER"

SSH_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_ARGS=(-i "$SSH_KEY")
fi

REMOTE_ENV=$(cat <<EOF
REPO_URL='${REPO_URL}'
REPO_DIR='${REPO_DIR}'
APP_DIR='${APP_DIR}'
BRANCH='${BRANCH}'
APP_NAME='${APP_NAME}'
APP_IMAGE='${APP_IMAGE}'
OLLAMA_IMAGE='${OLLAMA_IMAGE}'
OLLAMA_MODEL='${OLLAMA_MODEL}'
APP_PORT='${APP_PORT}'
OLLAMA_VOLUME='${OLLAMA_VOLUME}'
NETWORK_NAME='${NETWORK_NAME}'
EOF
)

step "Deploying from GitHub on ${VM_USER}@${VM_HOST}"
ssh "${SSH_ARGS[@]}" "${VM_USER}@${VM_HOST}" "${REMOTE_ENV} bash -s" <<'REMOTE'
set -euo pipefail

if ! command -v git >/dev/null 2>&1 || ! command -v podman >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git podman
  elif command -v sudo >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
    sudo yum install -y git podman
  else
    echo "Install git and podman on the VM, then run this script again." >&2
    exit 1
  fi
fi

if command -v podman >/dev/null 2>&1; then
  CLI=podman
elif command -v docker >/dev/null 2>&1; then
  CLI=docker
else
  echo "Neither podman nor docker was found on the VM." >&2
  exit 1
fi

echo "[remote] Using ${CLI}"

if [[ -d "${REPO_DIR}/.git" ]]; then
  cd "${REPO_DIR}"
  git fetch origin "${BRANCH}"
  git checkout "${BRANCH}"
  git pull --ff-only origin "${BRANCH}"
else
  git clone --branch "${BRANCH}" "${REPO_URL}" "${REPO_DIR}"
  cd "${REPO_DIR}"
fi

cd "${APP_DIR}"

echo "[remote] Building app image ${APP_IMAGE}"
"${CLI}" build -t "${APP_IMAGE}" .

"${CLI}" network exists "${NETWORK_NAME}" >/dev/null 2>&1 || "${CLI}" network create "${NETWORK_NAME}"
"${CLI}" volume exists "${OLLAMA_VOLUME}" >/dev/null 2>&1 || "${CLI}" volume create "${OLLAMA_VOLUME}"

"${CLI}" rm -f ollama >/dev/null 2>&1 || true
"${CLI}" run -d \
  --name ollama \
  --network "${NETWORK_NAME}" \
  -v "${OLLAMA_VOLUME}:/root/.ollama" \
  "${OLLAMA_IMAGE}"

echo "[remote] Waiting for Ollama"
for i in $(seq 1 90); do
  if "${CLI}" exec ollama ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if "${CLI}" exec ollama ollama list | grep -q "${OLLAMA_MODEL}"; then
  echo "[remote] Model ${OLLAMA_MODEL} already exists"
else
  "${CLI}" exec ollama ollama pull "${OLLAMA_MODEL}"
fi

"${CLI}" rm -f "${APP_NAME}" >/dev/null 2>&1 || true
"${CLI}" run -d \
  --name "${APP_NAME}" \
  --network "${NETWORK_NAME}" \
  -p "${APP_PORT}:8080" \
  -e OLLAMA_BASE_URL='http://ollama:11434' \
  -e OLLAMA_MODEL="${OLLAMA_MODEL}" \
  "${APP_IMAGE}"

echo "[remote] Running containers:"
"${CLI}" ps
REMOTE

step "Done. Open http://${VM_HOST}:${APP_PORT}"
step "Make sure the VM security list/NSG allows inbound TCP ${APP_PORT}."
