#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-spring-ai-chat-demo}"
APP_IMAGE="${APP_IMAGE:-${OCIR_REPOSITORY:-}:$(printf '%s' "${IMAGE_TAG:-v1}")}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:1b}"
VM_USER="${VM_USER:-opc}"
SSH_KEY="${SSH_KEY:-}"
APP_PORT="${APP_PORT:-8080}"
OLLAMA_VOLUME="${OLLAMA_VOLUME:-ollama}"
NETWORK_NAME="${NETWORK_NAME:-spring-ai-demo-net}"
OCIR_REGISTRY="${OCIR_REGISTRY:-${OCIR_SERVER:-mx-queretaro-1.ocir.io}}"
OCIR_USERNAME="${OCIR_USERNAME:-qazwsx.qazwsx244000@gmail.com}"

step() {
  printf '[vm-deploy] %s\n' "$1"
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
  local current_value="${!var_name:-}"
  local value

  if [[ -n "$current_value" ]]; then
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

ask_secret() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"
  local value

  if [[ -n "$current_value" ]]; then
    return
  fi

  read -r -s -p "${prompt}: " value
  printf '\n'

  if [[ -z "$value" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

need ssh

if [[ -z "$APP_IMAGE" || "$APP_IMAGE" == ":${IMAGE_TAG:-v1}" ]]; then
  printf "APP_IMAGE could not be inferred. Run 'source .cloudshell.env' or set APP_IMAGE explicitly.\n" >&2
  exit 1
fi

ask VM_HOST "Public IP or DNS of the Always Free compute VM"
ask VM_USER "SSH user" "$VM_USER"
ask OCIR_REGISTRY "OCIR registry" "$OCIR_REGISTRY"
ask OCIR_USERNAME "OCIR username"
ask_secret OCIR_AUTH_TOKEN "OCI auth token for remote OCIR login"

SSH_ARGS=()
if [[ -n "$SSH_KEY" ]]; then
  SSH_ARGS=(-i "$SSH_KEY")
fi

REMOTE_ENV=$(cat <<EOF
APP_NAME='${APP_NAME}'
APP_IMAGE='${APP_IMAGE}'
OLLAMA_IMAGE='${OLLAMA_IMAGE}'
OLLAMA_MODEL='${OLLAMA_MODEL}'
APP_PORT='${APP_PORT}'
OLLAMA_VOLUME='${OLLAMA_VOLUME}'
NETWORK_NAME='${NETWORK_NAME}'
OCIR_REGISTRY='${OCIR_REGISTRY}'
OCIR_USERNAME='${OCIR_USERNAME}'
OCIR_AUTH_TOKEN='${OCIR_AUTH_TOKEN}'
EOF
)

step "Deploying containers on ${VM_USER}@${VM_HOST}"
ssh "${SSH_ARGS[@]}" "${VM_USER}@${VM_HOST}" "${REMOTE_ENV} bash -s" <<'REMOTE'
set -euo pipefail

if command -v podman >/dev/null 2>&1; then
  CLI=podman
elif command -v docker >/dev/null 2>&1; then
  CLI=docker
else
  echo "Neither podman nor docker was found on the VM. Install podman or use Oracle Linux with podman available." >&2
  exit 1
fi

echo "[remote] Using ${CLI}"

echo "[remote] Logging in to ${OCIR_REGISTRY}"
printf '%s' "${OCIR_AUTH_TOKEN}" | "${CLI}" login "${OCIR_REGISTRY}" --username "${OCIR_USERNAME}" --password-stdin

"${CLI}" network exists "${NETWORK_NAME}" >/dev/null 2>&1 || "${CLI}" network create "${NETWORK_NAME}"
"${CLI}" volume exists "${OLLAMA_VOLUME}" >/dev/null 2>&1 || "${CLI}" volume create "${OLLAMA_VOLUME}"

"${CLI}" rm -f ollama >/dev/null 2>&1 || true
"${CLI}" run -d \
  --name ollama \
  --network "${NETWORK_NAME}" \
  -v "${OLLAMA_VOLUME}:/root/.ollama" \
  "${OLLAMA_IMAGE}"

echo "[remote] Waiting for Ollama"
for i in $(seq 1 60); do
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

"${CLI}" pull "${APP_IMAGE}"
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
