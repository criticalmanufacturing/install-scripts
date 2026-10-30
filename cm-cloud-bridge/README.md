# Install the CM Cloud Bridge

Connect your application to Critical Manufacturing on an Ubuntu server or in your
existing Kubernetes or OpenShift cluster.

## 1. Save your connection files

Save the private connection file supplied by Critical Manufacturing in a private folder:

- `link.yaml` — your private connection file.

Have the connector name, application address, and port supplied by Critical
Manufacturing ready. If `app-values.yaml` exists, the installer uses it. Otherwise,
it asks for these three values interactively, including in Kubernetes mode.
The settings file is optional and can supply more specific configuration; you do
not need to create or edit one for a basic installation.

For **Native Ubuntu** or **Podman on Ubuntu**, use Ubuntu 24.04 or 26.04 with
systemd on an amd64 or arm64 server. Run as your normal login user with sudo
access. Helm and kubectl are not required.

For **Helm**, use a workstation with Bash, curl, Helm 3.8+, and kubectl configured
for your cluster. Your administrator must provide access to install Helm releases
in the namespace you select, with Linux amd64 or arm64 nodes on Kubernetes
1.25+. Critical Manufacturing supplies registry credentials when required.

The machine running the command needs Bash, curl, and HTTPS access to
`raw.githubusercontent.com` and `criticalmanufacturing.io`. Ubuntu servers also
need access to download system packages and build dependencies; cluster nodes
need access to `criticalmanufacturing.io`. The connector must reach your
application and the cloud endpoints supplied by Critical Manufacturing.

## 2. Run the installation command

Open a terminal in that folder and run:

```bash
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/cm-cloud-bridge/install.sh | bash
```

Choose **Native Ubuntu**, **Podman on Ubuntu**, or **Helm** when prompted. Run
Ubuntu installations on the server that will host the connector. The first native
build can take several minutes. Ubuntu installs configure the CLI path for future
Bash terminals and set the CLI platform to match Native or Podman. They print
an export command to activate both settings in the current terminal.

For Helm, select the Kubernetes namespace when prompted; press Enter to use
`default`. Passing `--namespace NAME` uses that namespace without asking.
Check the cluster shown on screen and confirm with `y`. Enter registry
credentials only if requested; the token is hidden while you type.

To skip the menu, add `-s -- --mode native`, `-s -- --mode podman`, or
`-s -- --mode helm` after `bash`. Ubuntu installations default to release `1.0.0`;
Helm selects the latest stable release. Add `--version VERSION` after the mode
to pin the release supplied by Critical Manufacturing. The selected version is shown
before installation. Wait for installation to finish successfully.

If your files have different names or locations, add `--values /path/to/app-values.yaml`
and `--link-file /path/to/link.yaml` after the mode.

Helm upgrades briefly interrupt connector traffic. Keep the same release and
namespace when retrying or upgrading.

## 3. Confirm your application connection

Tell your Critical Manufacturing contact that installation completed so they can
confirm an application request through the cloud connection.

If installation reports an error, stop and send that error to your contact.
The installer prints the path to an installation log when it finishes, including
on failure. Send that log to your Critical Manufacturing contact for help. It is
saved as `cm-cloud-bridge-install-*.log` in the current folder, or in the temporary
folder if the current folder is not writable. The log is readable only by your
user; keep it private because it can contain server names and application addresses.
After the issue is resolved, rerun the same command with the same mode, version,
connector identity, and namespace. For Helm, also keep the same release name.

Keep `link.yaml` and any registry token private. Ubuntu installations retain private
connection material on the server; Helm stores it in Kubernetes and Helm release
history. Do not include connection files, credentials, or Secret contents in
support messages.

For another application, ask your contact for the appropriate settings. The
default Helm release is `cm-cloud-bridge` in namespace `default`. Rerunning
Helm without `--version` can select a newer stable release.
