#!/usr/bin/env bash
set -euo pipefail

step() {
  printf '[undeploy] %s\n' "$1"
}

step "Deleting app resources"
kubectl delete -f k8s/app-service.yaml --ignore-not-found=true
kubectl delete -f k8s/app-deployment.yaml --ignore-not-found=true

step "Deleting Ollama service and deployment"
kubectl delete -f k8s/ollama-service.yaml --ignore-not-found=true
kubectl delete -f k8s/ollama-deployment.yaml --ignore-not-found=true

step "Leaving PVC in place: k8s/ollama-pvc.yaml"
step "To delete the PVC manually later: kubectl delete -f k8s/ollama-pvc.yaml"
