#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.cloudshell.env}"
SECRETS_FILE="${SECRETS_FILE:-.cloudshell.secrets.env}"
AUTH_TOKEN_DESCRIPTION="${AUTH_TOKEN_DESCRIPTION:-spring-ai-chat-demo-ocir}"
AUTO_ACCEPT_DEFAULTS="${AUTO_ACCEPT_DEFAULTS:-true}"

step() {
  printf '[cloudshell] %s\n' "$1"
}

warn() {
  printf '[cloudshell][warn] %s\n' "$1" >&2
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "Command '%s' was not found.\n" "$1" >&2
    exit 1
  fi
}

ask_optional() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"
  local value

  if [[ -n "$current_value" ]]; then
    return
  fi

  if [[ "$AUTO_ACCEPT_DEFAULTS" == "true" && -n "$default_value" ]]; then
    export "$var_name=$default_value"
    step "Using ${var_name}=${default_value}"
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    read -r -p "${prompt}: " value
  fi

  export "$var_name=$value"
}

ask_required() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"

  ask_optional "$var_name" "$prompt" "$default_value"
  if [[ -z "${!var_name:-}" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi
}

ask_secret_optional() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"
  local value

  if [[ -n "$current_value" ]]; then
    return
  fi

  read -r -s -p "${prompt}: " value
  printf '\n'
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

default_region() {
  if [[ -n "${OCI_REGION:-}" ]]; then
    printf '%s' "$OCI_REGION"
  elif [[ -n "${OCI_CLI_REGION:-}" ]]; then
    printf '%s' "$OCI_CLI_REGION"
  else
    printf 'mx-queretaro-1'
  fi
}

region_key_for() {
  case "$1" in
    mx-queretaro-1) printf 'qro' ;;
    us-ashburn-1) printf 'iad' ;;
    us-phoenix-1) printf 'phx' ;;
    eu-frankfurt-1) printf 'fra' ;;
    uk-london-1) printf 'lhr' ;;
    *) printf '' ;;
  esac
}

default_ocir_server() {
  local region="$1"
  printf 'ocir.%s.oci.oraclecloud.com' "$region"
}

discover_tenancy_ocid() {
  if [[ -n "${OCI_TENANCY:-}" ]]; then
    printf '%s' "$OCI_TENANCY"
  elif [[ -n "${OCI_CS_TENANCY:-}" ]]; then
    printf '%s' "$OCI_CS_TENANCY"
  else
    oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true
  fi
}

discover_user_ocid() {
  if [[ -n "${OCI_USER_OCID:-}" ]]; then
    printf '%s' "$OCI_USER_OCID"
  elif [[ -n "${OCI_CS_USER_OCID:-}" ]]; then
    printf '%s' "$OCI_CS_USER_OCID"
  elif [[ -n "${OCI_CLI_PROFILE:-}" ]]; then
    oci setup repair-file-permissions --file "$HOME/.oci/config" >/dev/null 2>&1 || true
    awk -v profile="[$OCI_CLI_PROFILE]" '
      $0 == profile { active=1; next }
      /^\[/ { active=0 }
      active && /^user=/ { sub(/^user=/, ""); print; exit }
    ' "$HOME/.oci/config" 2>/dev/null || true
  else
    awk '
      $0 == "[DEFAULT]" { active=1; next }
      /^\[/ { active=0 }
      active && /^user=/ { sub(/^user=/, ""); print; exit }
    ' "$HOME/.oci/config" 2>/dev/null || true
  fi
}

discover_username() {
  local user_ocid="$1"
  if [[ -n "${OCI_USERNAME:-}" ]]; then
    printf '%s' "$OCI_USERNAME"
  elif [[ -n "${OCI_CS_USER_NAME:-}" ]]; then
    printf '%s' "$OCI_CS_USER_NAME"
  elif [[ -n "$user_ocid" ]]; then
    oci iam user get --user-id "$user_ocid" --query 'data.name' --raw-output 2>/dev/null || true
  fi
}

create_auth_token() {
  local user_ocid="$1"
  local token

  token="$(oci iam auth-token create \
    --user-id "$user_ocid" \
    --description "$AUTH_TOKEN_DESCRIPTION" \
    --query 'data.token' \
    --raw-output 2>/dev/null || true)"

  printf '%s' "$token"
}

ocir_login() {
  local cli="$1"
  local server="$2"
  local username="$3"
  local token="$4"

  printf '%s' "$token" | "$cli" login "$server" --username "$username" --password-stdin
}

need oci

CONTAINER_CLI="$(detect_container_cli)"
TENANCY_NAMESPACE="$(oci os ns get --query data --raw-output 2>/dev/null || true)"
TENANCY_OCID="$(discover_tenancy_ocid)"
USER_OCID="$(discover_user_ocid)"
OCI_USER_NAME="$(discover_username "$USER_OCID")"
REGION_DEFAULT="$(default_region)"
REGION_KEY_DEFAULT="$(region_key_for "$REGION_DEFAULT")"
if [[ -z "$REGION_KEY_DEFAULT" ]]; then
  REGION_KEY_DEFAULT="$REGION_DEFAULT"
fi

step "Preparing OCI Cloud Shell for this demo."
step "This works for the VM container flow and stores values that can also be reused for OKE later."
step "Using container CLI: ${CONTAINER_CLI}"

ask_required OCI_REGION "OCI region" "$REGION_DEFAULT"
export OCI_CLI_REGION="$OCI_REGION"

ask_optional COMPARTMENT_OCID "Existing compartment OCID for resources. Press Enter to use tenancy/root" "$TENANCY_OCID"
if [[ -z "$COMPARTMENT_OCID" ]]; then
  COMPARTMENT_OCID="$TENANCY_OCID"
fi
if [[ -z "$COMPARTMENT_OCID" ]]; then
  printf "Could not infer tenancy/root compartment OCID. Re-run and paste a compartment OCID.\n" >&2
  exit 1
fi

ask_required OCIR_REGION_KEY "OCIR region key, for example qro, iad, phx" "$REGION_KEY_DEFAULT"
ask_required OCIR_NAMESPACE "Tenancy namespace" "$TENANCY_NAMESPACE"
ask_required OCIR_REPO_PATH "OCIR repository path" "spring-ai-chat-demo"
ask_required USER_OCID "OCI user OCID for creating an auth token" "$USER_OCID"

OCIR_SERVER="${OCIR_SERVER:-$(default_ocir_server "$OCI_REGION")}"
OCIR_REPOSITORY="${OCIR_SERVER}/${OCIR_NAMESPACE}/${OCIR_REPO_PATH}"

DEFAULT_OCIR_USERNAME="${OCIR_NAMESPACE}"
if [[ -n "$OCI_USER_NAME" ]]; then
  DEFAULT_OCIR_USERNAME="${OCIR_NAMESPACE}/${OCI_USER_NAME}"
fi
ask_required OCIR_USERNAME "OCIR username" "$DEFAULT_OCIR_USERNAME"

if [[ -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  if [[ "$AUTO_ACCEPT_DEFAULTS" == "true" ]]; then
    CREATE_TOKEN="Y"
  else
    read -r -p "Create a new OCI auth token for OCIR now? [Y/n]: " CREATE_TOKEN
    CREATE_TOKEN="${CREATE_TOKEN:-Y}"
  fi
  if [[ "$CREATE_TOKEN" =~ ^[Yy]$ ]]; then
    step "Creating OCI auth token '${AUTH_TOKEN_DESCRIPTION}' for user ${USER_OCID}"
    OCIR_AUTH_TOKEN="$(create_auth_token "$USER_OCID")"
    if [[ -z "$OCIR_AUTH_TOKEN" ]]; then
      warn "Could not create the auth token automatically. You may not have permission, or your identity provider requires creating it in Console."
    fi
  fi
fi

if [[ -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  ask_secret_optional OCIR_AUTH_TOKEN "Paste OCI auth token for OCIR login"
fi
if [[ -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  printf "OCIR_AUTH_TOKEN is required to login and push images.\n" >&2
  exit 1
fi

step "Logging in to ${OCIR_SERVER}"
if ! ocir_login "$CONTAINER_CLI" "$OCIR_SERVER" "$OCIR_USERNAME" "$OCIR_AUTH_TOKEN"; then
  warn "Login failed with ${OCIR_SERVER}."
  LEGACY_OCIR_SERVER="${OCIR_REGION_KEY}.ocir.io"
  if [[ "$LEGACY_OCIR_SERVER" != "$OCIR_SERVER" ]]; then
    warn "Trying legacy OCIR endpoint ${LEGACY_OCIR_SERVER}."
    if ocir_login "$CONTAINER_CLI" "$LEGACY_OCIR_SERVER" "$OCIR_USERNAME" "$OCIR_AUTH_TOKEN"; then
      OCIR_SERVER="$LEGACY_OCIR_SERVER"
      OCIR_REPOSITORY="${OCIR_SERVER}/${OCIR_NAMESPACE}/${OCIR_REPO_PATH}"
    else
      warn "Legacy login also failed."
      unset OCIR_AUTH_TOKEN
    fi
  else
    unset OCIR_AUTH_TOKEN
  fi
fi

if [[ -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  warn "Most OCIR login failures are caused by OCIR_USERNAME format or an invalid auth token."
  warn "Username examples: <namespace>/<username> or <namespace>/<identity-domain>/<email>."
  ask_required OCIR_USERNAME "Re-enter OCIR username"
  ask_secret_optional OCIR_AUTH_TOKEN "Paste OCI auth token"
  step "Retrying login to ${OCIR_SERVER}"
  ocir_login "$CONTAINER_CLI" "$OCIR_SERVER" "$OCIR_USERNAME" "$OCIR_AUTH_TOKEN"
fi

cat > "$ENV_FILE" <<EOF
export OCI_REGION='${OCI_REGION}'
export OCI_CLI_REGION='${OCI_REGION}'
export COMPARTMENT_OCID='${COMPARTMENT_OCID}'
export TENANCY_OCID='${TENANCY_OCID}'
export USER_OCID='${USER_OCID}'
export OCIR_REGION_KEY='${OCIR_REGION_KEY}'
export OCIR_SERVER='${OCIR_SERVER}'
export OCIR_NAMESPACE='${OCIR_NAMESPACE}'
export OCIR_REPO_PATH='${OCIR_REPO_PATH}'
export OCIR_USERNAME='${OCIR_USERNAME}'
export OCIR_REPOSITORY='${OCIR_REPOSITORY}'
export IMAGE_NAME='spring-ai-chat-demo'
export IMAGE_TAG='v1'
export PUSH_IMAGE='true'
export CONTAINER_CLI='${CONTAINER_CLI}'
EOF

cat > "$SECRETS_FILE" <<EOF
export OCIR_AUTH_TOKEN='${OCIR_AUTH_TOKEN}'
EOF

chmod 600 "$ENV_FILE" "$SECRETS_FILE"

step "Wrote non-secret settings to ${ENV_FILE}"
step "Wrote secret token to ${SECRETS_FILE}"
step "Next: source ${ENV_FILE} && source ${SECRETS_FILE} && bash build.sh"
step "For VM deployment: bash oci-create-free-vm.sh, then source .oci-vm.env && bash vm-deploy.sh"
