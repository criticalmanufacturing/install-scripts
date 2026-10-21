# SaaS Connector image and Helm chart

This image runs a native Skupper router inside one ordinary Linux container.
The dedicated Bash entrypoint uses Skupper CLI 2.2.3's **Linux** platform to render
configuration, then replaces itself with **skrouterd 3.5.3**. There is no Podman,
Docker daemon, systemd, sudo, package installation, or Kubernetes API access
inside the running container. The existing VM installer is separate.

The Dockerfile extends the [official router image](https://github.com/skupperproject/skupper-router/blob/3.5.3/Containerfile),
`quay.io/skupper/skupper-router:3.5.3`, adding only the CLI and Bash scripts.
The base uses Red Hat UBI and already contains Proton and the other router
dependencies. We do not compile the router or its dependencies. Python is an
embedded upstream router dependency; our entrypoint is Bash. No OpenSSL checks
are run. The publishing workflow targets Docker Hub.

## Build and test with Docker first

From the repository root:

```bash
docker build -f saas-connector/container/Dockerfile -t saas-connector:dev .
bash saas-connector/tests/test_container.sh
```

The Docker test uses synthetic credentials and an isolated network. It creates a
cloud-equivalent native router, HTTP backend, and two connector sites. It verifies
real HTTP traffic across an authenticated TLS link, separate app routing, container
restart, cloud outage/reconnection, backend readiness failure, and graceful shutdown.
The connector runs as UID `1000710001` with a read-only root filesystem, all
capabilities dropped, and no privilege escalation. It does not use your cloud
endpoint or any production link file.

Image startup requires `CONNECTOR_NAME`, `APP_IP`, and `APP_PORT`; it reads the
Link YAML at `/input/link.yaml` by default. Optional variables are `SITE_NAME`
(default: hostname in lowercase), `NAMESPACE` (default: `default`), `ROUTING_KEY`
(default: connector name), `LINK_FILE`, and `TIMEOUT` (default: 180 seconds).
Mount a writable disposable directory at `/output` and temporary space at `/tmp`.
The entrypoint privately copies its read-only link input and rebuilds only its
generated namespace state on restart.

## Deploy with Helm

Use a published image tag. For a local Kubernetes test, first load the Docker
image into the cluster's node image store and use `image.repository=saas-connector`
and `image.tag=dev` instead of the Docker Hub image.

Create an application values file outside the repository:

```yaml
connectorName: another-app
appIp: "192.168.1.13"
appPort: 7990
image:
  tag: "sha-<published-commit>"
# Only when cluster DNS needs an override:
# cloudIp: "63.187.234.201"
```

Install from the repository root, supplying the generated cloud link file:

```bash
helm upgrade --install another-app ./saas-connector/helm/saas-connector \
  --namespace connectivity \
  --create-namespace \
  -f app-values.yaml \
  --set-file linkYaml=link.yaml \
  --wait
```

The chart creates a Deployment and a Secret, without installing the upstream
chart, Skupper CRDs, an operator, Roles, or cluster-wide permissions. Each release
runs one app and one router, with the release name as its default site name.
Use a different release and connector name to add another app. The existing cloud
site needs a Listener with the same routing key, which defaults to the connector
name. Changing a release's values updates that app; other releases are unaffected.

`linkYaml`, `connectorName`, `appIp`, `appPort`, and `image.tag` are required.
`appIp` accepts a reachable IP address or DNS name, including a Kubernetes Service.
Optional `siteName`, `routingKey`, `cloudHost`, `cloudIp`, and `timeout` correspond
to the VM script's inputs. The internal Skupper namespace comes from Helm's
`--namespace`; it is isolated inside the pod's disposable workspace.

The cloud hostname is inferred from the first Link endpoint, including files
with Windows line endings or multiple YAML documents. With `cloudIp`, Kubernetes
`hostAliases` maps that hostname in the pod; the Link's host/port and TLS identity
remain intact. Normal cluster DNS is used without the override.

The supplied file includes private credentials. It is stored in a Kubernetes
Secret **and Helm release history** when using `--set-file`; protect both.
Credential changes alter the pod checksum and trigger a replacement. Upgrades use
`Recreate` to keep one active router per release and briefly interrupt connections.
No persistent volume is needed; the original link credentials come from the Secret.

The chart's application label changes with this rename. For an existing Helm
release, recreate its Deployment once before upgrading: Kubernetes does not allow
changing a Deployment's selector. Keep the same release name, values, and link
file. This briefly interrupts connections.

## OpenShift and Kubernetes

The chart uses standard APIs for Kubernetes 1.25+ and corresponding OpenShift 4.x
versions. The image supports arbitrary non-root UIDs without an `/etc/passwd`
entry. The chart leaves UID and fsGroup selection to the cluster, uses a read-only
root filesystem and writable `emptyDir` volumes, disables the service-account API
token, drops all capabilities, and uses `RuntimeDefault` seccomp. No custom SCC,
`anyuid`, privileged container, host socket, host network, Ingress, or OpenShift
Route is needed for the connector.

Pods must have a network route and permitted egress to the cloud Link endpoints
and application address. An image cannot provide a missing route to a private
customer network; arrange that connectivity in the cluster infrastructure.

Startup/liveness probes check the local management listener. Readiness also
checks the application's TCP port. These probes do not prove an authenticated
cloud link or an application response. Inspect live router errors with:

```bash
kubectl logs -n connectivity deployment/another-app
```

Then send an application request to the existing cloud Listener Service.
Cloud outages leave the router running and reconnecting.

Inside the pod, `skupper` defaults to the Linux platform and the `NAMESPACE`
provided by Helm, so you can run:

```bash
skupper site status
skupper link status
skupper connector status
```

Explicit `--namespace` / `-n` and `--platform` / `-p` flags override those defaults.
This also works through `oc exec`; no shell alias is required. Docker uses
namespace `default` unless you supply `NAMESPACE`.

Plain `skupper link status`, including namespace flags, queries the running
router's local TLS management interface using the image's existing `skmanage`.
It prints live JSON with each link's name, endpoint, cost, `connectionStatus`,
and `connectionMsg`. `SUCCESS` means connected; `CONNECTING` means retrying;
`FAILED` includes the connection error. The query fails if the local router
cannot be contacted, rather than reporting a saved status. TLS certificate and
hostname verification remain enabled.

Other status commands and link-status variants with a link name or output
options retain the upstream CLI's rendered resource output. The original CLI
is also available directly as `skupper-cli`. Application traffic still needs
an end-to-end request through the cloud Listener.

Actual OpenShift acceptance is left to the cluster owner. Deploy into your
project with the Helm command above, then inspect admission and startup:

```bash
oc get pods -n connectivity -l app.kubernetes.io/instance=another-app
oc get pods -n connectivity -l app.kubernetes.io/instance=another-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{" SCC="}{.metadata.annotations.openshift\.io/scc}{" UID="}{.spec.containers[0].securityContext.runAsUser}{"\n"}{end}'
oc logs -n connectivity deployment/another-app
```

Verify the cluster's restricted SCC admitted the pod without granting `anyuid`,
then send a request through the cloud Listener and repeat after deleting the pod.
Use an existing project and omit `--create-namespace` if your account cannot
create namespaces.

## Docker Hub publishing

The GitHub Actions workflow `SaaS Connector container and Helm` builds/tests pull requests
without publishing. Main-branch component changes and manual dispatch publish
`criticalmanufacturing/saas-connector:sha-<full-commit>`. A component tag such as
`saas-connector-v0.1.0` additionally publishes image tag `0.1.0`.
Images are built for linux/amd64 and linux/arm64.

Create the public Docker Hub repository `criticalmanufacturing/saas-connector`
and configure repository or organization Actions secrets:

- `DOCKERHUB_USERNAME`: account allowed to push to that organization repository.
- `DOCKERHUB_TOKEN`: that account's Docker Hub access token with push permission.

The workflow validates on amd64 before publishing the multi-architecture image.
Publication requires the configured credentials; they are never needed by PR tests.
Helm can use another registry or mirror through `image.repository` and optional
`imagePullSecrets`.

## Validation limits

Docker verifies real traffic, arbitrary UIDs, and filesystem restrictions.
Actual OpenShift SCC admission and pod networking remain for your OpenShift test.
Local arm64 execution and Docker Hub publication are also pending. See the
[validation record](../tests/container-validation.md).
