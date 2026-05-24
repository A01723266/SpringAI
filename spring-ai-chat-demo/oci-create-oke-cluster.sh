#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.oci-oke.env}"
CLUSTER_NAME="${CLUSTER_NAME:-spring-ai-chat-demo-oke}"
VCN_NAME="${VCN_NAME:-spring-ai-chat-demo-oke-vcn}"
NODE_POOL_NAME="${NODE_POOL_NAME:-spring-ai-chat-demo-pool}"
K8S_VERSION="${K8S_VERSION:-}"
NODE_SHAPE="${NODE_SHAPE:-VM.Standard.A1.Flex}"
NODE_OCPUS="${NODE_OCPUS:-1}"
NODE_MEMORY_GB="${NODE_MEMORY_GB:-6}"
NODE_COUNT="${NODE_COUNT:-1}"
NODE_IMAGE_NAME="${NODE_IMAGE_NAME:-}"
VCN_CIDR="${VCN_CIDR:-10.90.0.0/16}"
LB_SUBNET_CIDR="${LB_SUBNET_CIDR:-10.90.1.0/24}"
NODE_SUBNET_CIDR="${NODE_SUBNET_CIDR:-10.90.2.0/24}"

step() {
  printf '[oci-oke] %s\n' "$1"
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

first_id() {
  local query_text="$1"
  shift
  oci "$@" --query "$query_text" --raw-output 2>/dev/null || true
}

need oci
need kubectl

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

TENANCY_OCID="${TENANCY_OCID:-}"
if [[ -z "$TENANCY_OCID" ]]; then
  TENANCY_OCID="$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
fi
REGION_DEFAULT="$(detect_region)"

ask COMPARTMENT_OCID "Compartment OCID for OKE. Press Enter to use tenancy/root" "$TENANCY_OCID"
ask OCI_REGION "OCI region" "$REGION_DEFAULT"
export OCI_CLI_REGION="$OCI_REGION"

step "Finding availability domains"
AD1="$(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" --query 'data[0].name' --raw-output)"

if [[ -z "$K8S_VERSION" ]]; then
  K8S_VERSION="$(oci ce cluster-options get --cluster-option-id all --query 'data."kubernetes-versions"[-1]' --raw-output)"
fi
step "Using Kubernetes version ${K8S_VERSION}"

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
IGW_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}-igw' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network internet-gateway list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$IGW_ID" || "$IGW_ID" == "null" ]]; then
  IGW_ID="$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "${VCN_NAME}-igw" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating route table"
RT_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}-rt' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network route-table list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$RT_ID" || "$RT_ID" == "null" ]]; then
  RT_ID="$(oci network route-table create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "${VCN_NAME}-rt" \
    --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"${IGW_ID}\"}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating security list"
SL_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}-sl' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network security-list list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$SL_ID" || "$SL_ID" == "null" ]]; then
  SL_ID="$(oci network security-list create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "${VCN_NAME}-sl" \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
    --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"all"}]' \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating public subnets"
LB_SUBNET_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}-lb-subnet' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$LB_SUBNET_ID" || "$LB_SUBNET_ID" == "null" ]]; then
  LB_SUBNET_ID="$(oci network subnet create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "${VCN_NAME}-lb-subnet" \
    --cidr-block "$LB_SUBNET_CIDR" \
    --route-table-id "$RT_ID" \
    --security-list-ids "[\"${SL_ID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

NODE_SUBNET_ID="$(first_id "data[?\"display-name\"=='${VCN_NAME}-node-subnet' && \"lifecycle-state\"!='TERMINATED'] | [0].id" network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID")"
if [[ -z "$NODE_SUBNET_ID" || "$NODE_SUBNET_ID" == "null" ]]; then
  NODE_SUBNET_ID="$(oci network subnet create \
    --compartment-id "$COMPARTMENT_OCID" \
    --vcn-id "$VCN_ID" \
    --display-name "${VCN_NAME}-node-subnet" \
    --cidr-block "$NODE_SUBNET_CIDR" \
    --route-table-id "$RT_ID" \
    --security-list-ids "[\"${SL_ID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output)"
fi

step "Finding or creating OKE cluster"
CLUSTER_ID="$(first_id "data[?name=='${CLUSTER_NAME}' && \"lifecycle-state\"!='DELETED'] | [0].id" ce cluster list --compartment-id "$COMPARTMENT_OCID")"
if [[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]]; then
  oci ce cluster create \
    --compartment-id "$COMPARTMENT_OCID" \
    --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION" \
    --vcn-id "$VCN_ID" \
    --endpoint-subnet-id "$LB_SUBNET_ID" \
    --service-lb-subnet-ids "[\"${LB_SUBNET_ID}\"]" \
    --endpoint-public-ip-enabled true \
    --wait-for-state SUCCEEDED >/dev/null

  CLUSTER_ID="$(first_id "data[?name=='${CLUSTER_NAME}' && \"lifecycle-state\"!='DELETED'] | [0].id" ce cluster list --compartment-id "$COMPARTMENT_OCID")"
fi

if [[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]]; then
  printf "Could not find or create OKE cluster %s.\n" "$CLUSTER_NAME" >&2
  exit 1
fi

if [[ -z "$NODE_IMAGE_NAME" ]]; then
  step "Finding OKE-supported node image"
  NODE_IMAGE_NAME="$(oci ce node-pool-options get \
    --node-pool-option-id "$CLUSTER_ID" \
    --query 'data.sources[-1]."source-name"' \
    --raw-output)"
fi

ask NODE_IMAGE_NAME "OKE node image name" "$NODE_IMAGE_NAME"

step "Finding or creating node pool"
NODE_POOL_ID="$(first_id "data[?name=='${NODE_POOL_NAME}' && \"lifecycle-state\"!='DELETED'] | [0].id" ce node-pool list --compartment-id "$COMPARTMENT_OCID" --cluster-id "$CLUSTER_ID")"
if [[ -z "$NODE_POOL_ID" || "$NODE_POOL_ID" == "null" ]]; then
  oci ce node-pool create \
    --compartment-id "$COMPARTMENT_OCID" \
    --cluster-id "$CLUSTER_ID" \
    --name "$NODE_POOL_NAME" \
    --kubernetes-version "$K8S_VERSION" \
    --node-shape "$NODE_SHAPE" \
    --node-shape-config "{\"ocpus\":${NODE_OCPUS},\"memoryInGBs\":${NODE_MEMORY_GB}}" \
    --node-image-name "$NODE_IMAGE_NAME" \
    --placement-configs "[{\"availabilityDomain\":\"${AD1}\",\"subnetId\":\"${NODE_SUBNET_ID}\"}]" \
    --size "$NODE_COUNT" \
    --wait-for-state SUCCEEDED >/dev/null

  NODE_POOL_ID="$(first_id "data[?name=='${NODE_POOL_NAME}' && \"lifecycle-state\"!='DELETED'] | [0].id" ce node-pool list --compartment-id "$COMPARTMENT_OCID" --cluster-id "$CLUSTER_ID")"
fi

if [[ -z "$NODE_POOL_ID" || "$NODE_POOL_ID" == "null" ]]; then
  printf "Could not find or create OKE node pool %s.\n" "$NODE_POOL_NAME" >&2
  exit 1
fi

step "Creating kubeconfig"
oci ce cluster create-kubeconfig \
  --cluster-id "$CLUSTER_ID" \
  --file "$HOME/.kube/config" \
  --region "$OCI_REGION" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

cat > "$ENV_FILE" <<EOF
export COMPARTMENT_OCID='${COMPARTMENT_OCID}'
export OCI_REGION='${OCI_REGION}'
export CLUSTER_OCID='${CLUSTER_ID}'
export NODE_POOL_OCID='${NODE_POOL_ID}'
export VCN_ID='${VCN_ID}'
export LB_SUBNET_ID='${LB_SUBNET_ID}'
export NODE_SUBNET_ID='${NODE_SUBNET_ID}'
EOF

chmod 600 "$ENV_FILE"

step "OKE cluster created"
step "Wrote settings to ${ENV_FILE}"
step "Next: source .cloudshell.env && source ${ENV_FILE}"
step "Then: bash build.sh && export APP_IMAGE=\"\$OCIR_REPOSITORY:\$IMAGE_TAG\" && bash deploy.sh"
