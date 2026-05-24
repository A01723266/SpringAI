#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="${SECRET_NAME:-ocirsecret}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/config}"

step() {
  printf '[cloudshell] %s\n' "$1"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Command '%s' was not found.\n" "$1" >&2
    exit 1
  fi
}

need_env() {
  if [[ -z "${!1:-}" ]]; then
    printf "Set %s before running this script.\n" "$1" >&2
    exit 1
  fi
}

step "Checking required tools"
need oci
need kubectl

step "Checking required environment variables"
need_env CLUSTER_OCID
need_env OCI_REGION
need_env OCIR_SERVER
need_env OCIR_USERNAME
need_env OCIR_AUTH_TOKEN
need_env OCIR_EMAIL

step "Creating kubeconfig for OKE cluster"
mkdir -p "$(dirname "$KUBECONFIG_FILE")"
oci ce cluster create-kubeconfig \
  --cluster-id "$CLUSTER_OCID" \
  --file "$KUBECONFIG_FILE" \
  --region "$OCI_REGION" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

export KUBECONFIG="$KUBECONFIG_FILE"

step "Verifying cluster access"
kubectl get nodes

step "Showing StorageClasses"
kubectl get storageclass

step "Creating or updating Kubernetes image pull secret '${SECRET_NAME}'"
kubectl create secret docker-registry "$SECRET_NAME" \
  --docker-server="$OCIR_SERVER" \
  --docker-username="$OCIR_USERNAME" \
  --docker-password="$OCIR_AUTH_TOKEN" \
  --docker-email="$OCIR_EMAIL" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

step "Preparation complete"
step "Next: export IMAGE_TAG, OCIR_REPOSITORY, PUSH_IMAGE=true, then run: bash build.sh"
