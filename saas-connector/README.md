# Install the SaaS Connector

Connect your application to Critical Manufacturing using your existing Kubernetes
or OpenShift cluster.

## 1. Save your connection files

Critical Manufacturing supplies two files. Save them together in a private folder:

- `app-values.yaml` — your completed application settings.
- `link.yaml` — your private connection file.

You also receive a registry username and read-only token.
You do not need to edit the supplied files.

Use a workstation with Bash, curl, Helm 3.8+, and kubectl configured for your
cluster. Your administrator must provide access to install Helm releases in the
`connectivity` namespace, with Linux amd64 or arm64 nodes on Kubernetes 1.25+.
The workstation and cluster nodes need HTTPS access to `criticalmanufacturing.io`;
the workstation also needs `raw.githubusercontent.com`. The connector must be able
to reach your application and the cloud endpoints supplied by Critical Manufacturing.

## 2. Run the installation command

Open a terminal in that folder and run:

```bash
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/saas-connector/install.sh | bash
```

Check the cluster shown on screen and confirm with `y`. Enter your registry
username and token when prompted. The token is hidden while you type.

The installer selects the latest stable release and displays the version it will
install. If Critical Manufacturing asks you to use a specific version, add
`-s -- --version 0.0.1` after `bash`, using the supplied version.

Wait for:

```text
Connector installed successfully.
```

## 3. Confirm your application connection

Tell your Critical Manufacturing contact that installation completed so they can
confirm an application request through the cloud connection.

If installation reports an error, stop and send that error to your contact.
After the issue is resolved, rerun the same command; it updates the existing
installation. Keep the same release and namespace on retries and upgrades.

Keep `link.yaml` and your registry token private. Connection credentials are stored
in Kubernetes and Helm release history. Do not include these files or Secret
contents in support messages.

For another application, ask your contact for the appropriate command. The default
release is `saas-connector` in namespace `connectivity`. Rerunning without a version
uses the latest stable release available at that time; use `--version` to repeat
a particular release.
