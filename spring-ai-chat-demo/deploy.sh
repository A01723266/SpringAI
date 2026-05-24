#!/usr/bin/env bash
set -euo pipefail

APP_IMAGE="${APP_IMAGE:-spring-ai-chat-demo:local}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:1b}"
CREATE_OCIR_SECRET="${CREATE_OCIR_SECRET:-true}"
OCIR_SECRET_NAME="${OCIR_SECRET_NAME:-ocirsecret}"
OCIR_REGISTRY="${OCIR_REGISTRY:-${OCIR_SERVER:-mx-queretaro-1.ocir.io}}"
OCIR_USERNAME="${OCIR_USERNAME:-qazwsx.qazwsx244000@gmail.com}"

step() {
  printf '[deploy] %s\n' "$1"
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

if [[ "$CREATE_OCIR_SECRET" == "true" && "$APP_IMAGE" == "${OCIR_REGISTRY}"/* ]]; then
  ask_secret OCIR_AUTH_TOKEN "OCI auth token for Kubernetes image pull secret"
  step "Creating/updating Kubernetes image pull secret ${OCIR_SECRET_NAME}"
  kubectl create secret docker-registry "$OCIR_SECRET_NAME" \
    --docker-server="$OCIR_REGISTRY" \
    --docker-username="$OCIR_USERNAME" \
    --docker-password="$OCIR_AUTH_TOKEN" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
fi

step "Applying Ollama PVC, deployment, and service"
kubectl apply -f k8s/ollama-pvc.yaml
kubectl apply -f k8s/ollama-deployment.yaml
kubectl apply -f k8s/ollama-service.yaml

step "Waiting for Ollama to become ready"
kubectl rollout status deployment/ollama --timeout=300s

step "Ensuring model ${OLLAMA_MODEL} exists in the Ollama PVC"
if kubectl exec deployment/ollama -- ollama list | grep -q "${OLLAMA_MODEL}"; then
  step "Model ${OLLAMA_MODEL} already exists"
else
  kubectl exec deployment/ollama -- ollama pull "${OLLAMA_MODEL}"
fi

step "Applying app deployment with image ${APP_IMAGE}"
sed "s|spring-ai-chat-demo:local|${APP_IMAGE}|g" k8s/app-deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/app-service.yaml

step "Waiting for app to become ready"
kubectl rollout status deployment/spring-ai-chat-demo --timeout=300s

step "Deployment submitted"
step "Check status: kubectl get pods,svc"
step "Test locally: kubectl port-forward service/spring-ai-chat-demo-service 8080:8080"
