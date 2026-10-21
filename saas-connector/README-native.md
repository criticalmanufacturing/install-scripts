# SaaS Connector: native Ubuntu alternative

Use `setup-saas-connector-ubuntu-native.sh` to run Skupper directly on Ubuntu, without
Docker or Podman. Choose this installer or the existing Podman installer for a VM.
The Podman and native installers are separate files so you can compare them.

Run as your normal Ubuntu user with sudo access:

```bash
bash saas-connector/setup-saas-connector-ubuntu-native.sh
```

The script prompts for the same required inputs: link file, connector name,
application address, and application port. The site name defaults to the machine
hostname, the cloud hostname is inferred from the link file, and the namespace
defaults to `default`.

You can supply the same options as the current installer:

```bash
bash saas-connector/setup-saas-connector-ubuntu-native.sh \
  --link-file link.yaml \
  --connector-name another-app \
  --app-ip 192.168.1.13 \
  --app-port 7990
```

The native version installs CLI 2.2.3 and router 3.5.3. If the router is missing,
it builds the router and its Proton dependency from pinned sources and installs
it under `/usr/local`. The initial build needs development packages and takes a
few minutes; subsequent runs reuse the installed router. Python is an upstream
router dependency; the installer itself is Bash. No OpenSSL checks are run.

Skupper creates and enables `skupper-default.service` under your user systemd
manager. Lingering keeps it available after logout and at boot. For another
namespace, the service is `skupper-<namespace>.service`.

Running again with a new connector name adds an app. Reusing a connector name
updates it. Each rerun reloads the native router, preserving the other connectors
but briefly interrupting connections. The cloud needs a matching Listener.

Inspect the router with:

```bash
systemctl --user status skupper-default.service
journalctl --user -u skupper-default.service -n 50
```

Linux CLI status describes rendered configuration, rather than live cloud-link
health. Send an application request through the cloud Listener to verify traffic.
The script rejects a namespace already using Podman/Docker; it does not migrate
an existing container installation.

Validated on Ubuntu 24.04 amd64: source build, user systemd startup, authenticated
HTTP traffic between native sites, adding a second app, rerunning setup, and
restarting the service. Ubuntu 26.04 and arm64 have not been tested here.
