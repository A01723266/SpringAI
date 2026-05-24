# Deploying from OCI Cloud Shell Without OKE

This path is for an OCI Free Tier / Always Free setup without Kubernetes clusters. It uses:

- OCI Cloud Shell to build and push the Spring Boot app image to OCIR.
- An Always Free Compute VM to run two containers:
  - `ollama`, with a persistent container volume.
  - `spring-ai-chat-demo`, connected to Ollama over an internal container network.

OCI Cloud Shell uses Podman for container builds. Oracle also provides a Docker-compatible alias backed by Podman.

## 1. Clone the Repository

```bash
git clone <your-github-repo-url>
cd spring-ai-chat-demo
```

## 2. Prepare Cloud Shell, Compartment, and OCIR

Run:

```bash
bash cloudshell-prepare.sh
```

The script discovers what it can and uses detected defaults automatically. If something cannot be detected, it asks only for that missing value. By default it uses the tenancy/root compartment when OCI allows it.

- OCI region, for example `mx-queretaro-1`
- compartment OCID, optional and usually auto-filled with tenancy/root
- OCIR region key, for example `qro`, used only as a fallback
- tenancy namespace
- OCIR repository path
- OCIR username
- OCI user OCID, used to create an auth token
- OCI auth token, generated automatically when your permissions allow it

For OCIR, the script uses Oracle's recommended endpoint format by default:

```text
ocir.<region-identifier>.oci.oraclecloud.com
```

For Queretaro that is:

```text
ocir.mx-queretaro-1.oci.oraclecloud.com
```

If login fails, the script also tries the legacy OC1 endpoint:

```text
qro.ocir.io
```

To force the script to ask before accepting detected defaults:

```bash
AUTO_ACCEPT_DEFAULTS=false bash cloudshell-prepare.sh
```

It logs in to OCIR and writes:

- `.cloudshell.env` for non-secret values
- `.cloudshell.secrets.env` for the OCIR auth token

Load those settings:

```bash
source .cloudshell.env
source .cloudshell.secrets.env
```

## 3. Build and Push the App Image

```bash
bash build.sh
```

This pushes:

```text
<region-key>.ocir.io/<tenancy-namespace>/<repo-path>:v1
```

## 4. Create an Always Free Compute VM

You can create the basic VM/network/SSH key from Cloud Shell:

```bash
bash oci-create-free-vm.sh
```

The script asks for your compartment OCID and region, then creates:

- SSH key under `~/.ssh/spring-ai-chat-demo`
- VCN, public subnet, internet gateway, route table, and security list
- inbound rules for SSH `22` and app port `8080`
- Always Free eligible Compute VM using `VM.Standard.A1.Flex`

It writes the VM connection values to `.oci-vm.env`.

Alternatively, create the VM manually in OCI Console. Recommended:

- Image: Oracle Linux
- Shape: Ampere A1 Flex if available
- Public IP: enabled
- SSH key: your Cloud Shell public key or another key you control

Open inbound TCP `8080` in the VM security list or NSG if you want browser access from the internet.

## 5. Deploy Containers to the VM

Run from Cloud Shell:

```bash
source .cloudshell.env
source .cloudshell.secrets.env
source .oci-vm.env
bash vm-deploy.sh
```

The script asks for the VM public IP or DNS and then creates:

- container network `spring-ai-demo-net`
- volume `ollama`
- container `ollama`
- container `spring-ai-chat-demo`

It pulls `llama3.2:1b` into the VM's Ollama volume if missing.

Open:

```text
http://<vm-public-ip>:8080
```

## Useful Overrides

Use another image tag:

```bash
export IMAGE_TAG=v2
bash build.sh
export APP_IMAGE="$OCIR_REPOSITORY:v2"
bash vm-deploy.sh
```

Use another public port:

```bash
export APP_PORT=8081
bash vm-deploy.sh
```

Use a specific SSH key:

```bash
export SSH_KEY="$HOME/.ssh/id_rsa"
bash vm-deploy.sh
```

## Stop the App on the VM

SSH into the VM and run:

```bash
podman rm -f spring-ai-chat-demo
podman rm -f ollama
```

The `ollama` volume is not deleted automatically.

## Optional: Create an OKE Cluster

If your tenancy/compartment allows OKE, you can create a small OKE cluster:

```bash
source .cloudshell.env
bash oci-create-oke-cluster.sh
source .oci-oke.env
```

Then build/push and deploy with the Kubernetes manifests:

```bash
source .cloudshell.env
source .cloudshell.secrets.env
bash build.sh
export APP_IMAGE="$OCIR_REPOSITORY:$IMAGE_TAG"
bash deploy.sh
```

OKE can incur charges depending on your account, region, shapes, storage, and load balancers. The default app service is `ClusterIP`, but the OKE control plane, nodes, storage, and networking still belong to your OCI tenancy.
