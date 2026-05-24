#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.cloudshell.env}"

DEFAULT_OCI_REGION="${DEFAULT_OCI_REGION:-mx-queretaro-1}"
DEFAULT_OCIR_REGISTRY="${DEFAULT_OCIR_REGISTRY:-mx-queretaro-1.ocir.io}"
DEFAULT_OCIR_USERNAME="${DEFAULT_OCIR_USERNAME:-axthosg61i3c/qazwsx.qazwsx244000@gmail.com}"
DEFAULT_OCIR_NAMESPACE="${DEFAULT_OCIR_NAMESPACE:-axthosg61i3c}"
DEFAULT_OCIR_REPO_PATH="${DEFAULT_OCIR_REPO_PATH:-spring-ai-chat-demo}"
DEFAULT_IMAGE_TAG="${DEFAULT_IMAGE_TAG:-v1}"

step() {
  printf '[cloudshell] %s\n' "$1"
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

  if [[ -n "${!var_name:-}" && "${!var_name}" != *"<"* && "${!var_name}" != *">"* ]]; then
    return
  fi

  if [[ -n "${!var_name:-}" && ( "${!var_name}" == *"<"* || "${!var_name}" == *">"* ) ]]; then
    step "Ignoring placeholder value for ${var_name}: ${!var_name}"
    unset "$var_name"
  fi

  read -r -p "${prompt} [${default_value}]: " value
  value="${value:-$default_value}"

  if [[ -z "$value" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

ask_secret() {
  local var_name="$1"
  local prompt="$2"
  local value

  if [[ -n "${!var_name:-}" ]]; then
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

detect_container_cli() {
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1; then
    printf 'docker'
  else
    printf "Neither podman nor docker was found. OCI Cloud Shell normally includes podman.\n" >&2
    exit 1
  fi
}

need oci

CONTAINER_CLI="$(detect_container_cli)"

if [[ -z "${OCIR_NAMESPACE:-}" ]]; then
  DETECTED_NAMESPACE="$(oci os ns get --query data --raw-output 2>/dev/null || true)"
  DEFAULT_OCIR_NAMESPACE="${DETECTED_NAMESPACE:-$DEFAULT_OCIR_NAMESPACE}"
fi

step "Preparing OCIR login with the registry format that was verified to work."
step "Using container CLI: ${CONTAINER_CLI}"

ask OCI_REGION "OCI region" "$DEFAULT_OCI_REGION"
ask OCIR_REGISTRY "OCIR registry" "$DEFAULT_OCIR_REGISTRY"
ask OCIR_USERNAME "OCIR login username" "$DEFAULT_OCIR_USERNAME"
ask OCIR_NAMESPACE "OCIR tenancy namespace for image path" "$DEFAULT_OCIR_NAMESPACE"
ask OCIR_REPO_PATH "OCIR repository path" "$DEFAULT_OCIR_REPO_PATH"
ask IMAGE_TAG "Image tag" "$DEFAULT_IMAGE_TAG"
ask_secret OCIR_AUTH_TOKEN "OCI auth token for OCIR login"

OCIR_REPOSITORY="${OCIR_REGISTRY}/${OCIR_NAMESPACE}/${OCIR_REPO_PATH}"

step "Logging in to ${OCIR_REGISTRY} as ${OCIR_USERNAME}"
printf '%s' "$OCIR_AUTH_TOKEN" | "${CONTAINER_CLI}" login "$OCIR_REGISTRY" --username "$OCIR_USERNAME" --password-stdin

cat > "$ENV_FILE" <<EOF
export OCI_REGION='${OCI_REGION}'
export OCI_CLI_REGION='${OCI_REGION}'
export OCIR_REGISTRY='${OCIR_REGISTRY}'
export OCIR_SERVER='${OCIR_REGISTRY}'
export OCIR_USERNAME='${OCIR_USERNAME}'
export OCIR_NAMESPACE='${OCIR_NAMESPACE}'
export OCIR_REPO_PATH='${OCIR_REPO_PATH}'
export OCIR_REPOSITORY='${OCIR_REPOSITORY}'
export IMAGE_NAME='spring-ai-chat-demo'
export IMAGE_TAG='${IMAGE_TAG}'
export PUSH_IMAGE='true'
export CONTAINER_CLI='${CONTAINER_CLI}'
EOF

chmod 600 "$ENV_FILE"

step "Wrote non-secret settings to ${ENV_FILE}"
step "Auth token was used for login only and was not written to disk."
step "Next: source ${ENV_FILE} && bash build.sh"
