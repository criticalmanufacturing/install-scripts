# SaaS Connector container and Helm validation record

Validated 21 October 2026 in the development workspace.

## Passed

- Built the connector for linux/amd64 from the official Skupper router 3.5.3
  image, adding Skupper CLI 2.2.3 and the Bash entrypoint.
- Bash syntax, ShellCheck, Helm lint and template/schema checks.
- Real Docker tests, using generated test credentials and a cloud-equivalent
  router: authenticated inter-site HTTP traffic to a backend, two independent
  sites/apps, container restart with existing generated state, cloud outage and
  reconnection, backend readiness failure, and graceful SIGTERM shutdown.
- UID `1000710001` without a matching passwd entry, read-only root filesystem,
  all capabilities dropped, no privilege escalation, and read-only link input.
- Linux configuration generation and router startup without Podman, systemd,
  sudo, a Docker socket, or a Kubernetes API token inside the container.
- Existing Ubuntu VM shell tests still pass.
- CLI defaults checked on 22 October: plain `skupper link status` reads the
  container's non-default namespace; explicit namespace and platform flags work.
- Live link status queried through the existing TLS management interface:
  `SUCCESS` while connected, `FAILED`/`CONNECTING` during a cloud outage, and
  `SUCCESS` after reconnection.

CI runs the Docker test and Helm rendering checks. Test credentials and networks
are disposable and unrelated to the customer's cloud deployment.

## Not verified

- Actual OpenShift SCC admission and traffic on an OpenShift cluster; the user
  will perform this acceptance test.
- arm64 execution in this workspace. The upstream base supports arm64, and the
  publication workflow builds both architectures; its remote run has not been
  executed here.
- Docker Hub publication; it requires the organization repository and configured
  `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` Actions secrets.
- Deployment and Service DNS traffic on Kubernetes with this image.
- Customer production ingress, credentials, private network routing, or traffic.

The image is designed for OpenShift's arbitrary UID and restricted permissions,
which are exercised in Docker. Those tests do not replace a live
OpenShift acceptance test. See [acceptance.md](acceptance.md).
