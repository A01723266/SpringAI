# Deploy desde OCI Cloud Shell en Free Tier

Este flujo evita OCIR y OKE. Es el mejor camino para tu cuenta Free Tier porque OCIR ya regreso `FREE_TIER_NOT_SUPPORTED` al intentar crear el repositorio.

La VM funciona como runner y servidor:

- Cloud Shell crea o prepara una VM Always Free.
- La VM clona el repo desde GitHub.
- La VM compila la imagen localmente con Podman.
- La VM corre dos contenedores: `ollama` y `spring-ai-chat-demo`.
- No se suben imagenes a OCIR.

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

## 2. Crear la VM Always Free

```bash
bash oci-create-free-vm.sh
```

Cuando pregunte el compartment, puedes usar tu compartment:

```text
ocid1.compartment.oc1..aaaaaaaahbmxbgpj5efimqcjv45p2ylwmcolt6s7bjrdjkepngrygiavupea
```

El script crea:

- Llave SSH RSA en `~/.ssh/spring-ai-chat-demo`
- VCN, subnet publica, internet gateway, route table y security list
- Reglas inbound para SSH `22` y app `8080`
- VM `VM.Standard.A1.Flex`

Al terminar escribe `.oci-vm.env`.

Si falla por `bootVolumeQuota Service limit reached`, tu cuenta no tiene cuota libre de boot volume en esa region/tenancy. En ese caso revisa si hay boot volumes en otro compartment o region, o intenta con:

```bash
export BOOT_VOLUME_GB=47
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

## OCIR y OKE

Los scripts `cloudshell-prepare.sh`, `build.sh`, `deploy.sh` y `k8s/` quedan disponibles por si mas adelante usas una cuenta/compartment donde OCIR y OKE esten habilitados.

En tu Free Tier actual no conviene usarlos como ruta principal porque OCIR rechazo la creacion del repositorio con `FREE_TIER_NOT_SUPPORTED`.
