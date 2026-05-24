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

need oci
need kubectl

TENANCY_OCID="${TENANCY_OCID:-}"
if [[ -z "$TENANCY_OCID" ]]; then
  TENANCY_OCID="$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
fi
REGION_DEFAULT="${OCI_CLI_REGION:-${OCI_REGION:-mx-queretaro-1}}"

ask COMPARTMENT_OCID "Compartment OCID for OKE. Press Enter to use tenancy/root" "$TENANCY_OCID"
ask OCI_REGION "OCI region" "$REGION_DEFAULT"
export OCI_CLI_REGION="$OCI_REGION"

step "Finding availability domains"
AD1="$(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" --query 'data[0].name' --raw-output)"

if [[ -z "$K8S_VERSION" ]]; then
  K8S_VERSION="$(oci ce cluster-options get --cluster-option-id all --query 'data."kubernetes-versions"[-1]' --raw-output)"
fi
step "Using Kubernetes version ${K8S_VERSION}"

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
  --display-name "${VCN_NAME}-igw" \
  --is-enabled true \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating route table"
RT_ID="$(oci network route-table create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "${VCN_NAME}-rt" \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"${IGW_ID}\"}]" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating security list"
SL_ID="$(oci network security-list create \
  --compartment-id "$COMPARTMENT_OCID" \
  --vcn-id "$VCN_ID" \
  --display-name "${VCN_NAME}-sl" \
  --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
  --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"all"}]' \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)"

step "Creating public subnets"
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

step "Creating OKE cluster"
CLUSTER_ID="$(oci ce cluster create \
  --compartment-id "$COMPARTMENT_OCID" \
  --name "$CLUSTER_NAME" \
  --kubernetes-version "$K8S_VERSION" \
  --vcn-id "$VCN_ID" \
  --endpoint-subnet-id "$LB_SUBNET_ID" \
  --service-lb-subnet-ids "[\"${LB_SUBNET_ID}\"]" \
  --endpoint-public-ip-enabled true \
  --wait-for-state ACTIVE \
  --query 'data.id' \
  --raw-output)"

step "Finding latest Oracle Linux image for node shape ${NODE_SHAPE}"
NODE_IMAGE_ID="$(oci compute image list \
  --compartment-id "$COMPARTMENT_OCID" \
  --operating-system "Oracle Linux" \
  --shape "$NODE_SHAPE" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --query 'data[0].id' \
  --raw-output)"

step "Creating node pool"
NODE_POOL_ID="$(oci ce node-pool create \
  --compartment-id "$COMPARTMENT_OCID" \
  --cluster-id "$CLUSTER_ID" \
  --name "$NODE_POOL_NAME" \
  --kubernetes-version "$K8S_VERSION" \
  --node-shape "$NODE_SHAPE" \
  --node-shape-config "{\"ocpus\":${NODE_OCPUS},\"memoryInGBs\":${NODE_MEMORY_GB}}" \
  --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${NODE_IMAGE_ID}\"}" \
  --placement-configs "[{\"availabilityDomain\":\"${AD1}\",\"subnetId\":\"${NODE_SUBNET_ID}\"}]" \
  --size "$NODE_COUNT" \
  --wait-for-state ACTIVE \
  --query 'data.id' \
  --raw-output)"

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
