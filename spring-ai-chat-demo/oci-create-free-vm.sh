#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.oci-vm.env}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/spring-ai-chat-demo}"
VM_NAME="${VM_NAME:-spring-ai-chat-demo-vm}"
VCN_NAME="${VCN_NAME:-spring-ai-chat-demo-vcn}"
SUBNET_NAME="${SUBNET_NAME:-spring-ai-chat-demo-subnet}"
IGW_NAME="${IGW_NAME:-spring-ai-chat-demo-igw}"
ROUTE_TABLE_NAME="${ROUTE_TABLE_NAME:-spring-ai-chat-demo-rt}"
SECURITY_LIST_NAME="${SECURITY_LIST_NAME:-spring-ai-chat-demo-sl}"
VCN_CIDR="${VCN_CIDR:-10.80.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.80.1.0/24}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
APP_PORT="${APP_PORT:-8080}"

step() {
  printf '[oci-vm] %s\n' "$1"
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

  if [[ -n "$current_value" ]]; then
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    read -r -p "${prompt}: " value
  fi

  if [[ -z "$value" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

query() {
  oci "$@" --raw-output
}

wait_for_lifecycle() {
  local resource_type="$1"
  local resource_id="$2"
  local desired_state="$3"

  step "Waiting for ${resource_type} ${resource_id} to become ${desired_state}"
  oci "$resource_type" get --"${resource_type##* }"-id "$resource_id" >/dev/null 2>&1 || true
}

need oci
need ssh-keygen

TENANCY_OCID="${TENANCY_OCID:-}"
if [[ -z "$TENANCY_OCID" ]]; then
  TENANCY_OCID="$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
fi
REGION_DEFAULT="${OCI_CLI_REGION:-mx-queretaro-1}"

ask COMPARTMENT_OCID "Compartment OCID for the VM and network. Press Enter to use tenancy/root" "$TENANCY_OCID"
ask OCI_REGION "OCI region" "$REGION_DEFAULT"

export OCI_CLI_REGION="$OCI_REGION"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  step "Creating SSH key at ${SSH_KEY_PATH}"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "spring-ai-chat-demo"
else
  step "Using existing SSH key ${SSH_KEY_PATH}"
fi

PUBLIC_KEY="$(cat "${SSH_KEY_PATH}.pub")"

step "Finding availability domain"
AD_NAME="$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_OCID" \
  --query 'data[0].name' \
  --raw-output)"

step "Creating VCN"
VCN_ID="$(oci network vcn create \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name "$VCN_NAME" \
  --cidr-block "$VCN_CIDR" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating internet gateway"
IGW_ID="$(oci network internet-gateway create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "$IGW_NAME" \
  --is-enabled true \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating route table"
ROUTE_TABLE_ID="$(oci network route-table create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "$ROUTE_TABLE_NAME" \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"${IGW_ID}\"}]" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating security list for SSH and app port ${APP_PORT}"
SECURITY_LIST_ID="$(oci network security-list create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "$SECURITY_LIST_NAME" \
  --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
  --ingress-security-rules "[{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}},{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":${APP_PORT},\"max\":${APP_PORT}}}}]" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating public subnet"
SUBNET_ID="$(oci network subnet create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "$SUBNET_NAME" \
  --cidr-block "$SUBNET_CIDR" \
  --route-table-id "$ROUTE_TABLE_ID" \
  --security-list-ids "[\"${SECURITY_LIST_ID}\"]" \
  --prohibit-public-ip-on-vnic false \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Finding latest Oracle Linux image for ${SHAPE}"
IMAGE_ID="$(oci compute image list \
  --compartment-id "$COMPARTMENT_OCID" \
  --operating-system "Oracle Linux" \
  --shape "$SHAPE" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --query 'data[0].id' \
  --raw-output)"

step "Creating Always Free eligible compute instance"
INSTANCE_ID="$(oci compute instance launch \
  --compartment-id "$COMPARTMENT_OCID" \
  --availability-domain "$AD_NAME" \
  --display-name "$VM_NAME" \
  --shape "$SHAPE" \
  --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
  --source-details "{\"sourceType\":\"image\",\"imageId\":\"${IMAGE_ID}\",\"bootVolumeSizeInGBs\":${BOOT_VOLUME_GB}}" \
  --subnet-id "$SUBNET_ID" \
  --assign-public-ip true \
  --metadata "{\"ssh_authorized_keys\":\"${PUBLIC_KEY}\"}" \
  --wait-for-state RUNNING \
  --query 'data.id' \
  --raw-output)"

step "Finding VM public IP"
VNIC_ID="$(oci compute instance list-vnics \
  --compartment-id "$COMPARTMENT_OCID" \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0].id' \
  --raw-output)"
VM_PUBLIC_IP="$(oci network vnic get \
  --vnic-id "$VNIC_ID" \
  --query 'data."public-ip"' \
  --raw-output)"

cat > "$ENV_FILE" <<EOF
export COMPARTMENT_OCID='${COMPARTMENT_OCID}'
export OCI_REGION='${OCI_REGION}'
export VM_HOST='${VM_PUBLIC_IP}'
export VM_USER='opc'
export SSH_KEY='${SSH_KEY_PATH}'
export APP_PORT='${APP_PORT}'
export INSTANCE_ID='${INSTANCE_ID}'
export VCN_ID='${VCN_ID}'
export SUBNET_ID='${SUBNET_ID}'
EOF

chmod 600 "$ENV_FILE"

step "VM created: ${VM_PUBLIC_IP}"
step "Wrote VM settings to ${ENV_FILE}"
step "Next: source .cloudshell.env && source ${ENV_FILE} && bash vm-deploy.sh"
