#!/usr/bin/env bash
set -euo pipefail

MODEL="${OLLAMA_MODEL:-llama3.2:1b}"

step() {
  printf '[setup] %s\n' "$1"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Command '%s' was not found. Install it before continuing.\n" "$1" >&2
    exit 1
  fi
}

container_cli() {
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1; then
    printf 'docker'
  else
    printf "Neither podman nor docker was found. OCI Cloud Shell normally includes podman.\n" >&2
    exit 1
  fi
}

step "Checking required tools"
need kubectl
need curl

CONTAINER_CLI="$(container_cli)"
step "Using container CLI: ${CONTAINER_CLI}"

if command -v oci >/dev/null 2>&1; then
  step "OCI CLI found"
else
  step "OCI CLI not found; this is OK unless you plan to push to OCIR or manage OKE from this machine"
fi

step "Checking container CLI"
"${CONTAINER_CLI}" version >/dev/null

step "Checking Kubernetes context"
kubectl config current-context
kubectl cluster-info >/dev/null

step "Checking local Ollama endpoint, if available"
if curl -fsS "http://localhost:11434/api/tags" >/dev/null 2>&1; then
  step "Local Ollama responds on http://localhost:11434"
else
  step "Local Ollama did not respond on http://localhost:11434; Kubernetes deploy will create its own Ollama service"
fi

step "Model expected by the demo: ${MODEL}"
step "Setup validation complete"
