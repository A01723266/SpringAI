# Deploying from OCI Cloud Shell

These steps assume the local Docker version of the demo already works and the repository has been pushed to GitHub.

OCI Cloud Shell includes Git, Maven, kubectl, OCI CLI, and Podman. Docker Engine is not installed in Oracle Linux 8-based Cloud Shell, but OCI provides a Docker-compatible alias backed by Podman.

## 1. Clone the repository

```bash
git clone <your-github-repo-url>
cd spring-ai-chat-demo
```

## 2. Configure OKE access

From the OKE cluster page in OCI Console, select **Access cluster**, choose **Cloud Shell Access**, and run the generated command. It looks like this:

```bash
oci ce cluster create-kubeconfig \
  --cluster-id <cluster-ocid> \
  --file "$HOME/.kube/config" \
  --region <region> \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
```

Then verify:

```bash
kubectl get nodes
kubectl get storageclass
```

If your OKE cluster does not have a default StorageClass, set one in `k8s/ollama-pvc.yaml` before deploying.

## 3. Build and push the app image to OCIR

Log in to OCIR with an OCI auth token, not your OCI account password:

```bash
podman login <region-key>.ocir.io
```

Build and push:

```bash
export IMAGE_NAME=spring-ai-chat-demo
export IMAGE_TAG=v1
export OCIR_REPOSITORY=<region-key>.ocir.io/<tenancy-namespace>/<repo>/spring-ai-chat-demo
export PUSH_IMAGE=true
bash build.sh
```

Example repository format:

```text
iad.ocir.io/mytenancynamespace/demo/spring-ai-chat-demo
```

## 4. Allow OKE to pull from OCIR

Create a registry secret in the target namespace:

```bash
kubectl create secret docker-registry ocirsecret \
  --docker-server=<region-key>.ocir.io \
  --docker-username='<tenancy-namespace>/<oci-username>' \
  --docker-password='<oci-auth-token>' \
  --docker-email='<email>'
```

If your user is federated, the username usually includes the identity domain:

```text
<tenancy-namespace>/<identity-domain>/<email>
```

The deployment already references a secret named `ocirsecret`, so use that exact name unless you also update `k8s/app-deployment.yaml`.

## 5. Deploy

```bash
export APP_IMAGE=<region-key>.ocir.io/<tenancy-namespace>/<repo>/spring-ai-chat-demo:v1
bash deploy.sh
```

The deploy script creates Ollama with a PVC, waits for it to be ready, pulls `llama3.2:1b` into the PVC, and deploys the Spring Boot app.

## 6. Test with port-forward

```bash
kubectl port-forward service/spring-ai-chat-demo-service 8080:8080
```

Open:

```text
http://localhost:8080
```

## 7. Undeploy

```bash
bash undeploy.sh
```

The script removes only this demo's Deployment and Service resources. It does not delete the Ollama PVC automatically.
