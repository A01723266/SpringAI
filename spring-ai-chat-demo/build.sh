#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-spring-ai-chat-demo}"
IMAGE_TAG="${IMAGE_TAG:-local}"
LOCAL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
OCIR_REPOSITORY="${OCIR_REPOSITORY:-}"
OCIR_REGISTRY="${OCIR_REGISTRY:-${OCIR_SERVER:-}}"
OCIR_NAMESPACE="${OCIR_NAMESPACE:-}"
OCIR_REPO_PATH="${OCIR_REPO_PATH:-spring-ai-chat-demo}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"
CONTAINER_CLI="${CONTAINER_CLI:-}"

step() {
  printf '[build] %s\n' "$1"
}

detect_container_cli() {
  if [[ -n "${CONTAINER_CLI}" ]]; then
    printf '%s' "${CONTAINER_CLI}"
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1; then
    printf 'docker'
  else
    printf "Neither podman nor docker was found. OCI Cloud Shell normally includes podman.\n" >&2
    exit 1
  fi
}

CLI="$(detect_container_cli)"

step "Using container CLI: ${CLI}"
step "Building ${LOCAL_IMAGE}"
"${CLI}" build -t "${LOCAL_IMAGE}" .

if [[ "${PUSH_IMAGE}" == "true" ]]; then
  if [[ -z "${OCIR_REPOSITORY}" && -n "${OCIR_REGISTRY}" && -n "${OCIR_NAMESPACE}" ]]; then
    OCIR_REPOSITORY="${OCIR_REGISTRY}/${OCIR_NAMESPACE}/${OCIR_REPO_PATH}"
  fi

  if [[ -z "${OCIR_REPOSITORY}" ]]; then
    printf "Set OCIR_REPOSITORY before PUSH_IMAGE=true. Example: mx-queretaro-1.ocir.io/axthosg61i3c/spring-ai-chat-demo\n" >&2
    exit 1
  fi

  REMOTE_IMAGE="${OCIR_REPOSITORY}:${IMAGE_TAG}"
  step "Tagging ${REMOTE_IMAGE}"
  "${CLI}" tag "${LOCAL_IMAGE}" "${REMOTE_IMAGE}"

  step "Pushing ${REMOTE_IMAGE}"
  "${CLI}" push "${REMOTE_IMAGE}"

  step "Use APP_IMAGE=${REMOTE_IMAGE} when running deploy.sh"
else
  step "Skipping push. Set PUSH_IMAGE=true and OCIR_REPOSITORY to push to OCIR."
fi
