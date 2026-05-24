#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-spring-ai-chat-demo}"
IMAGE_TAG="${IMAGE_TAG:-local}"
LOCAL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
OCIR_REPOSITORY="${OCIR_REPOSITORY:-}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"

step() {
  printf '[build] %s\n' "$1"
}

step "Building ${LOCAL_IMAGE}"
docker build -t "${LOCAL_IMAGE}" .

if [[ "${PUSH_IMAGE}" == "true" ]]; then
  if [[ -z "${OCIR_REPOSITORY}" ]]; then
    printf "Set OCIR_REPOSITORY before PUSH_IMAGE=true. Example: iad.ocir.io/namespace/repo/spring-ai-chat-demo\n" >&2
    exit 1
  fi

  REMOTE_IMAGE="${OCIR_REPOSITORY}:${IMAGE_TAG}"
  step "Tagging ${REMOTE_IMAGE}"
  docker tag "${LOCAL_IMAGE}" "${REMOTE_IMAGE}"

  step "Pushing ${REMOTE_IMAGE}"
  docker push "${REMOTE_IMAGE}"

  step "Use APP_IMAGE=${REMOTE_IMAGE} when running deploy.sh"
else
  step "Skipping push. Set PUSH_IMAGE=true and OCIR_REPOSITORY to push to OCIR."
fi
