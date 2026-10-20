# Skupper: connect a private application to cloud Kubernetes

Expose one TCP application through a cloud Kubernetes Service. The application
can run behind an Ubuntu VM or be reachable from another Kubernetes cluster.
SAP, HTTP, database protocols, and other TCP applications use the same setup.

The scripts use Skupper **2.2.3**, one router per site, and explicit routing keys.
All deployment addresses and names come from arguments. Application TLS and
authentication remain the application's responsibility.

| Run on | Script | Purpose |
| --- | --- | --- |
| Ubuntu VM | `setup-skupper-ubuntu.sh` | Rootless Podman connector to an existing cloud site |
| Kubernetes administrator workstation | `setup-skupper-cloud-listener.sh` | Cloud site, Traefik passthrough, Listener, and private link export |
| Kubernetes administrator workstation | `setup-skupper-kubernetes-connector.sh` | Connector site in another cluster, optionally with a cloud IP override |

The Kubernetes scripts arrive in separate PRs based on this change. Their usage
is documented in `cloud-listener.md` and `kubernetes-connector.md` in those PRs.
See [architecture.md](architecture.md) for traffic flow and security boundaries.

## Ubuntu VM

Use a dedicated, permanent nonroot login account on Ubuntu **24.04 or 26.04 LTS**,
amd64 or arm64. Log in directly through SSH or the console; do not use `sudo bash`.
The account needs sudo, a local home directory, a working systemd user session,
cgroup v2, and administrator-assigned nonoverlapping subordinate UID/GID ranges
of at least 65,536 entries. Cloned VMs need unique machine IDs.

The cloud Skupper site, Traefik endpoint, and matching Listener must already exist.
Transfer its generated Link/Secret YAML securely, outside the repository. Use
separate client credentials and a distinct routing key for each isolated target.

```bash
# Set these variables to your deployment values first.
chmod 600 "$LINK_FILE"
bash ./skupper/setup-skupper-ubuntu.sh \
  --link-file "$LINK_FILE" \
  --cloud-host "$CLOUD_HOST" --cloud-ip "$CLOUD_IP" \
  --app-ip "$APP_IP" --app-port "$APP_PORT" \
  --routing-key "$ROUTING_KEY"
```

`--routing-key` is mandatory and must match the cloud Listener, regardless of
resource names. `--app-ip` is an IPv4 or IPv6 literal on the VM; the Kubernetes
alternative also accepts application DNS names.

Optional arguments:

| Argument | Default / behavior |
| --- | --- |
| `--site-name NAME` | Stable name derived from hostname, machine ID, and user ID |
| `--namespace NAME` | Site name; isolates local site state |
| `--connector-name NAME` | `application`; keep it stable when updating a target |
| `--timeout SECONDS` | 180 per convergence step; range 10–3600 |
| `--dry-run` | Read-only input validation; requires existing Python 3 and PyYAML |

Names and routing keys must be lowercase DNS labels of at most 63 characters.
Cloud hostname must be a fully qualified DNS name matching every Link endpoint.
The cloud port comes from the Link bundle; no extra VM port argument is needed.
Run `--help` for the complete interface. Ubuntu is checked even before help.

### What is installed

Only Ubuntu packages, with `--no-install-recommends`, and the checksum-verified
Skupper CLI are installed. Dependencies pulled by apt are managed by Ubuntu.

| Package | Reason |
| --- | --- |
| `podman` | Rootless controller/router containers; requires version 4.9 or newer |
| `uidmap` | Rootless user namespace mappings |
| `dbus-user-session` | User systemd session and long-running user services |
| `curl`, `ca-certificates` | HTTPS release download |
| `python3`, `python3-yaml` | IP/TCP checks, structured YAML validation, hosts updates |

Standard Ubuntu tools such as Bash, tar, coreutils, and util-linux are assumed.
No Kubernetes CLI, Docker, netcat, jq, or separate OpenSSL executable is required
on the VM. Host networking avoids additional user-mode networking packages.
Ubuntu Universe must be available. No third-party apt repository is added.

Setup needs access to Ubuntu mirrors, GitHub release assets, Quay container images,
the cloud endpoint ports in the Link file, and the application TCP port. Configure
any required proxy or firewall rules before running the script.

### Safe GitHub execution

Download the complete script from a reviewed commit, verify its independently
trusted SHA256, and execute it as the login user. Set the three variables below
from the reviewed release/commit; never embed link credentials in URLs.

```bash
(
  set -euo pipefail
  umask 077
  setup_file=$(mktemp)
  trap 'rm -f -- "$setup_file"' EXIT
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 120 --retry 3 \
    "https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/${INSTALL_SCRIPTS_COMMIT}/skupper/setup-skupper-ubuntu.sh" \
    --output "$setup_file"
  printf '%s  %s\n' "$TRUSTED_SCRIPT_SHA256" "$setup_file" | sha256sum --check --status
  bash "$setup_file" \
    --link-file "$LINK_FILE" \
    --cloud-host "$CLOUD_HOST" --cloud-ip "$CLOUD_IP" \
    --app-ip "$APP_IP" --app-port "$APP_PORT" \
    --routing-key "$ROUTING_KEY"
)
```

### Reruns, changes, and recovery

Repeat the same command to reconcile. Identical resources are not reapplied.
Keep site, namespace, and connector names unchanged to update application IP/port
in place. Changing names creates additional resources; it does not remove old ones.

Changing the cloud IP updates `/etc/hosts` and recreates the router if its hosts
snapshot is stale. Active connections are interrupted briefly. The shared user
controller pauses during that refresh; use a dedicated account for this setup.
Unrelated hosts aliases are preserved and changed files receive timestamped backups.

The CLI is installed at `~/.local/bin/skupper`; private state lives under
`~/.local/share/skupper`. Setup enables lingering, `podman.socket`,
`podman-restart.service`, and `skupper-controller.service` for logout/reboot recovery.
Do not remove persistent certificates. Protect backups and the original link file.
Do not run with shell tracing or commit generated credentials.

Failures preserve partial state for repair and rerun. The script never resets
Podman storage, removes unrelated sites, or silently upgrades existing controllers.
It refuses unowned namespaces and incompatible versions. If interrupted during
a router refresh, restart `systemctl --user start skupper-controller.service`
and rerun. Hosts backups require manual review before restoration.

Useful diagnostics (set `LOCAL_NAMESPACE` to the namespace printed by setup):

```bash
"$HOME/.local/bin/skupper" --platform podman --namespace "$LOCAL_NAMESPACE" site status
"$HOME/.local/bin/skupper" --platform podman --namespace "$LOCAL_NAMESPACE" link status
"$HOME/.local/bin/skupper" --platform podman --namespace "$LOCAL_NAMESPACE" connector status
systemctl --user status podman.socket podman-restart.service skupper-controller.service
journalctl --user -u skupper-controller.service --no-pager -n 50
podman logs --tail 50 "${LOCAL_NAMESPACE}-skupper-router"
```

Review logs before sharing. Check VM CPU compatibility if a container fails with
an x86-64-v2 error. A hosts mapping cannot fix an expired certificate or incorrect
TLS hostname. Successful TCP probes do not prove application authentication or
correct application responses.

To retire a site, first stop its clients and revoke/replace its cloud-issued
credentials using your approved Skupper procedure. Use the pinned CLI to remove
only that site's resources. Disable shared services/lingering or uninstall the
controller only after confirming no other sites or containers use the account.
Remove only this setup's hosts mapping, preserving other aliases. Deleting the
local Link file alone does not revoke its certificate.

## Validation and maintenance

Run `bash -n skupper/setup-skupper-ubuntu.sh`,
`shellcheck -S style skupper/setup-skupper-ubuntu.sh`, and
`python3 -m unittest discover -s skupper/tests -p 'test_ubuntu.py'`.
Test dependencies are Bash, ShellCheck, Python 3, and PyYAML. Tests never provision
the host or contact deployment addresses.

[tests/acceptance.md](tests/acceptance.md) describes required disposable live checks.
The automated suite uses fake credentials/commands; it does not prove real
systemd startup, Podman behavior, mutual TLS, or reboot recovery.

For a Skupper update, review the upstream release and tagged source, update the
version and both trusted CLI SHA256 values together, verify CLI output/API behavior,
review controller/router image changes, and rerun all automated and live checks.
Keep Kubernetes script versions aligned. Container tags and Ubuntu package
versions follow the pinned CLI and Ubuntu repositories respectively; this script
does not pin every transitive dependency or perform migrations automatically.

Sources: [Skupper local-system setup](https://skupper.io/docs/system-cli/site-configuration.html),
[Link resources](https://skupper.io/docs/system-cli/site-linking.html), and
[Skupper 2.2.3 source](https://github.com/skupperproject/skupper/tree/2.2.3).
