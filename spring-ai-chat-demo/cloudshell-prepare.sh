#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.cloudshell.env}"

DEFAULT_OCI_REGION="${DEFAULT_OCI_REGION:-}"
DEFAULT_COMPARTMENT_OCID="${DEFAULT_COMPARTMENT_OCID:-}"
DEFAULT_OCIR_REGISTRY="${DEFAULT_OCIR_REGISTRY:-}"
DEFAULT_OCIR_USERNAME="${DEFAULT_OCIR_USERNAME:-}"
DEFAULT_OCIR_NAMESPACE="${DEFAULT_OCIR_NAMESPACE:-}"
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
  local current_value="${!var_name:-}"
  local value

  if [[ -n "$current_value" && "$current_value" != *"<"* && "$current_value" != *">"* ]]; then
    default_value="$current_value"
  elif [[ -n "$current_value" ]]; then
    step "Ignoring placeholder value for ${var_name}: ${current_value}"
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

detect_region() {
  local region=""
  region="${OCI_CLI_REGION:-${OCI_REGION:-}}"
  if [[ -z "$region" && -f "$HOME/.oci/config" ]]; then
    region="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$HOME/.oci/config" 2>/dev/null || true)"
  fi
  if [[ -z "$region" ]]; then
    region="$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null || true)"
  fi
  printf '%s' "$region"
}

detect_tenancy_ocid() {
  local tenancy=""
  tenancy="$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
  if [[ -z "$tenancy" || "$tenancy" == "null" ]]; then
    tenancy="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$HOME/.oci/config" 2>/dev/null || true)"
  fi
  printf '%s' "$tenancy"
}

detect_namespace() {
  oci os ns get --query data --raw-output 2>/dev/null || true
}

detect_user_name() {
  local user_ocid=""
  local user_name=""
  user_ocid="$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$HOME/.oci/config" 2>/dev/null || true)"
  if [[ -n "$user_ocid" ]]; then
    user_name="$(oci iam user get --user-id "$user_ocid" --query 'data.name' --raw-output 2>/dev/null || true)"
  fi
  if [[ -z "$user_name" || "$user_name" == "null" ]]; then
    user_name="${OCI_USERNAME:-${USER:-}}"
  fi
  printf '%s' "$user_name"
}

DEFAULT_OCI_REGION="${DEFAULT_OCI_REGION:-$(detect_region)}"
DEFAULT_COMPARTMENT_OCID="${DEFAULT_COMPARTMENT_OCID:-$(detect_tenancy_ocid)}"
DEFAULT_OCIR_NAMESPACE="${DEFAULT_OCIR_NAMESPACE:-$(detect_namespace)}"
DEFAULT_OCIR_REGISTRY="${DEFAULT_OCIR_REGISTRY:-${DEFAULT_OCI_REGION}.ocir.io}"

DETECTED_USER_NAME="$(detect_user_name)"
if [[ -n "$DEFAULT_OCIR_NAMESPACE" && -n "$DETECTED_USER_NAME" ]]; then
  DEFAULT_OCIR_USERNAME="${DEFAULT_OCIR_USERNAME:-${DEFAULT_OCIR_NAMESPACE}/${DETECTED_USER_NAME}}"
else
  DEFAULT_OCIR_USERNAME="${DEFAULT_OCIR_USERNAME:-${DETECTED_USER_NAME}}"
fi

step "Preparing OCIR login with detected values. Press Enter to accept a value in brackets."
step "Using container CLI: ${CONTAINER_CLI}"

ask OCI_REGION "OCI region" "$DEFAULT_OCI_REGION"
ask COMPARTMENT_OCID "Compartment OCID for OCIR repository. Press Enter to use tenancy/root" "$DEFAULT_COMPARTMENT_OCID"
ask OCIR_REGISTRY "OCIR registry" "$DEFAULT_OCIR_REGISTRY"
ask OCIR_USERNAME "OCIR login username" "$DEFAULT_OCIR_USERNAME"
ask OCIR_NAMESPACE "OCIR tenancy namespace for image path" "$DEFAULT_OCIR_NAMESPACE"
ask OCIR_REPO_PATH "OCIR repository path" "$DEFAULT_OCIR_REPO_PATH"
ask IMAGE_TAG "Image tag" "$DEFAULT_IMAGE_TAG"
ask_secret OCIR_AUTH_TOKEN "OCI auth token for OCIR login"

OCIR_REPOSITORY="${OCIR_REGISTRY}/${OCIR_NAMESPACE}/${OCIR_REPO_PATH}"

step "Creating OCIR repository if it does not exist"
EXISTING_REPOSITORY_ID="$(oci artifacts container repository list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$OCIR_REPO_PATH" \
  --query 'data.items[0].id' \
  --raw-output 2>/dev/null || true)"

if [[ -z "$EXISTING_REPOSITORY_ID" || "$EXISTING_REPOSITORY_ID" == "null" ]]; then
  oci artifacts container repository create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$OCIR_REPO_PATH" \
    --is-public false >/dev/null
else
  step "OCIR repository already exists: ${OCIR_REPO_PATH}"
fi

step "Logging in to ${OCIR_REGISTRY} as ${OCIR_USERNAME}"
printf '%s' "$OCIR_AUTH_TOKEN" | "${CONTAINER_CLI}" login "$OCIR_REGISTRY" --username "$OCIR_USERNAME" --password-stdin

cat > "$ENV_FILE" <<EOF
export COMPARTMENT_OCID='${COMPARTMENT_OCID}'
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
