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
SHAPE="${SHAPE:-VM.Standard.E4.Flex}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-16}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
APP_PORT="${APP_PORT:-8080}"
FAULT_DOMAIN="${FAULT_DOMAIN:-}"
SHAPE_CANDIDATES="${SHAPE_CANDIDATES:-${SHAPE} VM.Standard.E5.Flex VM.Standard.E4.Flex VM.Standard.E3.Flex}"

step() {
  printf '[oci-vm] %s\n' "$1" >&2
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
    default_value="$current_value"
  fi

  read -r -p "${prompt} [${default_value}]: " value
  value="${value:-$default_value}"

  if [[ -z "$value" ]]; then
    printf "%s is required.\n" "$var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

query() {
  oci "$@" --raw-output
}

first_id() {
  local query_text="$1"
  shift
  oci "$@" --query "$query_text" --raw-output 2>/dev/null || true
}

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

need oci
need ssh-keygen

TENANCY_OCID="${TENANCY_OCID:-}"
if [[ -z "$TENANCY_OCID" ]]; then
  TENANCY_OCID="$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
fi
REGION_DEFAULT="$(detect_region)"

ask COMPARTMENT_OCID "Compartment OCID for the VM and network. Press Enter to use tenancy/root" "$TENANCY_OCID"
ask OCI_REGION "OCI region" "$REGION_DEFAULT"
ask SHAPE "VM shape" "$SHAPE"
ask OCPUS "VM OCPUs" "$OCPUS"
ask MEMORY_GB "VM memory GB" "$MEMORY_GB"
ask BOOT_VOLUME_GB "VM boot volume GB" "$BOOT_VOLUME_GB"

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

step "Finding or creating VCN"
VCN_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network vcn list --compartment-id "$COMPARTMENT_OCID")"
if [[ -z "$VCN_ID" || "$VCN_ID" == "null" ]]; then
  VCN_ID="$(oci network vcn create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$VCN_NAME" \
    --cidr-block "$VCN_CIDR" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating internet gateway"
IGW_ID="$(first_id "data[?\"display-name\"=='${IGW_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network internet-gateway list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$IGW_ID" || "$IGW_ID" == "null" ]]; then
  IGW_ID="$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "$IGW_NAME" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating route table"
ROUTE_TABLE_ID="$(first_id "data[?\"display-name\"=='${ROUTE_TABLE_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network route-table list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$ROUTE_TABLE_ID" || "$ROUTE_TABLE_ID" == "null" ]]; then
  ROUTE_TABLE_ID="$(oci network route-table create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "$ROUTE_TABLE_NAME" \
    --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"${IGW_ID}\"}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating security list for SSH and app port ${APP_PORT}"
SECURITY_LIST_ID="$(first_id "data[?\"display-name\"=='${SECURITY_LIST_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network security-list list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$SECURITY_LIST_ID" || "$SECURITY_LIST_ID" == "null" ]]; then
  SECURITY_LIST_ID="$(oci network security-list create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "$SECURITY_LIST_NAME" \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
    --ingress-security-rules "[{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}},{\"source\":\"0.0.0.0/0\",\"protocol\":\"6\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":${APP_PORT},\"max\":${APP_PORT}}}}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating public subnet"
SUBNET_ID="$(first_id "data[?\"display-name\"=='${SUBNET_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
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
fi

find_image_for_shape() {
  local shape="$1"

  oci compute image list \
    --compartment-id "$COMPARTMENT_OCID" \
    --operating-system "Oracle Linux" \
    --shape "$shape" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query 'data[0].id' \
    --raw-output 2>/dev/null || true
}

launch_instance() {
  local shape="$1"
  local fault_domain="$2"
  local image_id source_details

  image_id="$(find_image_for_shape "$shape")"
  if [[ -z "$image_id" || "$image_id" == "null" ]]; then
    step "No Oracle Linux image found for ${shape}"
    return 1
  fi

  source_details="{\"sourceType\":\"image\",\"imageId\":\"${image_id}\"}"
  if [[ -n "$BOOT_VOLUME_GB" ]]; then
    source_details="{\"sourceType\":\"image\",\"imageId\":\"${image_id}\",\"bootVolumeSizeInGBs\":${BOOT_VOLUME_GB}}"
  fi

  local args=(
    compute instance launch
    --compartment-id "$COMPARTMENT_OCID"
    --availability-domain "$AD_NAME"
    --display-name "$VM_NAME"
    --shape "$shape"
    --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}"
    --source-details "$source_details"
    --subnet-id "$SUBNET_ID"
    --assign-public-ip true
    --metadata "{\"ssh_authorized_keys\":\"${PUBLIC_KEY}\"}"
    --wait-for-state RUNNING
    --query 'data.id'
    --raw-output
  )

  if [[ -n "$fault_domain" ]]; then
    args+=(--fault-domain "$fault_domain")
    step "Trying ${shape} in ${fault_domain}"
  else
    step "Trying ${shape} without explicit fault domain"
  fi

  oci "${args[@]}"
}

step "Finding existing VM"
INSTANCE_ID="$(first_id "data[?\"display-name\"=='${VM_NAME}' && \"lifecycle-state\"!='TERMINATED'] | [0].id" compute instance list --compartment-id "$COMPARTMENT_OCID")"
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" ]]; then
  INSTANCE_STATE="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  if [[ "$INSTANCE_STATE" == "RUNNING" ]]; then
    step "Using existing running VM ${INSTANCE_ID}"
  elif [[ "$INSTANCE_STATE" == "STOPPED" ]]; then
    step "Starting existing VM ${INSTANCE_ID}"
    oci compute instance action --instance-id "$INSTANCE_ID" --action START --wait-for-state RUNNING >/dev/null
  else
    step "Existing VM is ${INSTANCE_STATE}; delete it manually if it is stuck and rerun this script"
    exit 1
  fi
else
  INSTANCE_ID=""
fi

if [[ -z "$INSTANCE_ID" ]]; then
  step "Creating compute instance"
  mapfile -t FAULT_DOMAINS < <(oci iam fault-domain list \
      --availability-domain "$AD_NAME" \
      --compartment-id "$COMPARTMENT_OCID" \
      --query 'join(`\n`, data[].name)' \
      --raw-output 2>/dev/null || true)

  if [[ -n "$FAULT_DOMAIN" ]]; then
    FAULT_DOMAINS=("$FAULT_DOMAIN")
  elif [[ "${#FAULT_DOMAINS[@]}" -eq 0 ]]; then
    FAULT_DOMAINS=("")
  else
    FAULT_DOMAINS=("" "${FAULT_DOMAINS[@]}")
  fi

  SEEN_SHAPES=""
  for candidate_shape in $SHAPE_CANDIDATES; do
    if [[ " ${SEEN_SHAPES} " == *" ${candidate_shape} "* ]]; then
      continue
    fi
    SEEN_SHAPES="${SEEN_SHAPES} ${candidate_shape}"

    for candidate_fault_domain in "${FAULT_DOMAINS[@]}"; do
      if INSTANCE_ID="$(launch_instance "$candidate_shape" "$candidate_fault_domain")"; then
        SHAPE="$candidate_shape"
        break 2
      fi
      step "No capacity or incompatible shape for ${candidate_shape} in ${candidate_fault_domain:-default placement}; trying next candidate"
      INSTANCE_ID=""
    done
  done
fi

if [[ -z "$INSTANCE_ID" ]]; then
  printf "Could not create the VM. OCI likely has no host capacity for the tried shapes: %s\n" "$SHAPE_CANDIDATES" >&2
  printf "Try again later, lower MEMORY_GB/OCPUS, or use another region if your tenancy allows it.\n" >&2
  exit 1
fi

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
export SHAPE='${SHAPE}'
export INSTANCE_ID='${INSTANCE_ID}'
export VCN_ID='${VCN_ID}'
export SUBNET_ID='${SUBNET_ID}'
EOF

chmod 600 "$ENV_FILE"

step "VM created: ${VM_PUBLIC_IP}"
step "Wrote VM settings to ${ENV_FILE}"
step "Next: source ${ENV_FILE} && bash vm-build-deploy-from-git.sh"
