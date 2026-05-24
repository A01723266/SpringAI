#!/usr/bin/env bash
set -euo pipefail

APP_IMAGE="${APP_IMAGE:-spring-ai-chat-demo:local}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:1b}"

step() {
  printf '[deploy] %s\n' "$1"
}

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
