# Deploy desde OCI Cloud Shell

Este proyecto soporta dos rutas:

- VM directa: simple y rapida para pruebas.
- OCIR + OKE: mas parecido al proyecto `OCIcons`, recomendado si tu cuenta nueva tiene creditos y OCIR/OKE habilitados.

Los scripts detectan valores desde OCI Cloud Shell y luego te preguntan para validarlos. Si el valor entre `[]` se ve bien, presiona Enter.

## Ruta A: VM directa recomendada

La VM funciona como runner y servidor:

- Cloud Shell crea o prepara una VM x86 con creditos de prueba.
- La VM clona el repo desde GitHub.
- La VM compila la imagen localmente con Podman.
- La VM corre dos contenedores: `ollama` y `spring-ai-chat-demo`.
- No se suben imagenes a OCIR.

Defaults recomendados para una cuenta Free Trial de 30 dias con creditos:

- Shape: `VM.Standard.E4.Flex`
- OCPU: `2`
- RAM: `16 GB`
- Boot volume: `100 GB`

El script prueba tambien `VM.Standard.E5.Flex` y `VM.Standard.E3.Flex` si el primer shape no tiene capacidad. Evitamos `A1.Flex` por default para no mezclar ARM con imagenes x86.

## Lo que hace OCIcons

El proyecto `OCIcons` usa Oracle DevOps Build:

- `build_spec.yaml` corre en un runner de Oracle DevOps.
- Hace login a OCIR.
- Ejecuta Maven y `docker build`.
- Hace `docker push` a OCIR.
- Luego configura `kubectl` y despliega a OKE.

Ese patron depende de OCIR y OKE. Para este proyecto lo adaptamos asi:

- En vez de DevOps Build runner: usamos una VM Always Free.
- En vez de OCIR: la imagen queda local en la VM.
- En vez de OKE: Podman corre app + Ollama en la VM.

## 1. Clonar el repo

```bash
git clone https://github.com/A01723266/SpringAI.git
cd SpringAI/spring-ai-chat-demo
```

## 2. Crear la VM

```bash
bash oci-create-free-vm.sh
```

Cuando pregunte el compartment, revisa el valor detectado. Si quieres usar el tenancy/root, presiona Enter.

El script crea:

- Llave SSH RSA en `~/.ssh/spring-ai-chat-demo`
- VCN, subnet publica, internet gateway, route table y security list
- Reglas inbound para SSH `22` y app `8080`
- VM x86 flexible para los creditos de prueba

Al terminar escribe `.oci-vm.env`.

Si falla por `bootVolumeQuota Service limit reached`, tu cuenta no tiene cuota libre de boot volume en esa region/tenancy. En ese caso revisa si hay boot volumes en otro compartment o region, o intenta con:

```bash
export BOOT_VOLUME_GB=50
bash oci-create-free-vm.sh
```

## 3. Compilar y desplegar desde GitHub en la VM

```bash
source .oci-vm.env
bash vm-build-deploy-from-git.sh
```

El script entra por SSH a la VM y ejecuta:

- instala `git` y `podman` si faltan
- clona o actualiza `https://github.com/A01723266/SpringAI.git`
- compila la imagen `spring-ai-chat-demo:local`
- crea red `spring-ai-demo-net`
- crea volumen persistente `ollama`
- levanta contenedor `ollama`
- descarga `llama3.2:1b` solo si falta
- levanta contenedor `spring-ai-chat-demo`

Abre:

```text
http://<VM_PUBLIC_IP>:8080
```

## Comandos utiles en la VM

Ver contenedores:

```bash
podman ps
```

Ver logs de la app:

```bash
podman logs -f spring-ai-chat-demo
```

Ver logs de Ollama:

```bash
podman logs -f ollama
```

Reiniciar solo la app desde Cloud Shell:

```bash
source .oci-vm.env
bash vm-build-deploy-from-git.sh
```

Detener contenedores en la VM:

```bash
podman rm -f spring-ai-chat-demo
podman rm -f ollama
```

El volumen `ollama` no se borra automaticamente.

## Ruta B: OCIR + OKE

Esta ruta es la equivalente conceptual a `OCIcons`: se construye imagen, se empuja a OCIR y Kubernetes la consume.

```bash
bash cloudshell-prepare.sh
source .cloudshell.env
bash build.sh
```

Luego crea OKE si no tienes cluster:

```bash
bash oci-create-oke-cluster.sh
source .oci-oke.env
```

Despliega:

```bash
export APP_IMAGE="$OCIR_REPOSITORY:$IMAGE_TAG"
bash deploy.sh
```

Prueba con port-forward:

```bash
kubectl port-forward service/spring-ai-chat-demo-service 8080:8080
```
