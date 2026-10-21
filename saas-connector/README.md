# SaaS Connector on Ubuntu

This Bash script follows the attached Ubuntu VM runbook: install prerequisites,
install Skupper 2.2.3, optionally map the cloud hostname, create the site, import
the link file, and connect the application. It uses Ubuntu command-line utilities;
there is no Python, PyYAML, or jq dependency.

For a Kubernetes or OpenShift deployment, use the separate
[connector image and Helm chart](container/README.md). It runs the native
router directly, with one app per Helm release and no Podman or Skupper operator.

## Run it

Sign in directly to the Ubuntu VM as the normal user with sudo access. Copy the
cloud administrator's Link YAML onto the VM, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/codex/skupper-ubuntu/saas-connector/setup-saas-connector-ubuntu.sh -o setup-saas-connector-ubuntu.sh
bash setup-saas-connector-ubuntu.sh
```

The URL uses the current development branch. Change `codex/skupper-ubuntu` to
`main` after merging.

The script asks for:

- The path to the supplied link file.
- The connector name, matching the cloud Listener's routing key.
- The application IP address and TCP port.
- An optional cloud ingress IP override. Press Enter to use existing DNS.

The site name defaults to the machine's hostname in lowercase. The cloud hostname
is read from the first endpoint in the Link YAML. Use `--site-name` or
`--cloud-host` to override either default.
Exported setup variables are also accepted; command-line options take precedence.
The local namespace defaults to `default`, matching the manual runbook commands.

Use Ubuntu **24.04 or 26.04 LTS**, amd64 or arm64. Run without `sudo bash`;
the script requests sudo for packages, lingering, and the optional hosts entry.
The cloud site and matching Listener must already exist.

You can also prefill answers with options; missing required values are still
requested. For example:

```bash
bash setup-saas-connector-ubuntu.sh \
  --link-file "$HOME/link.yaml" \
  --connector-name sap2-http \
  --app-ip 192.168.1.14 \
  --app-port 3000 \
  --cloud-ip 63.187.234.201
```

The IP override uses the hostname read from the link file. `curl ... | bash -s --`
is also supported because prompts read the terminal separately from the script.

## Expose another app

Reuse the link file and run setup with a new connector name and the new app's
address and port. For example:

```bash
curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/codex/skupper-ubuntu/saas-connector/setup-saas-connector-ubuntu.sh | bash -s -- \
  --link-file "link.yaml" \
  --connector-name "another-app" \
  --app-ip "192.168.1.13" \
  --app-port "7990"
```

Existing connectors remain configured. The cloud needs a Listener with routing
key `another-app`. Reusing an existing connector name updates that connector.

Keep the same site and namespace as the existing installation. The defaults are
the machine hostname and namespace `default`; add `--site-name` or `--namespace`
only when the existing installation uses different values.

## Retry an existing installation

For a retry of an installation with another site name, supply its original name
with `--site-name` (for example, `--site-name vm-ubuntu-3ff529abb032`) and its
original namespace with `--namespace`. Earlier installer versions used the site
name as the namespace; pass both names to continue one of those installations.
For example, use `--site-name asm --namespace asm` for an earlier script attempt,
or `--site-name asm` for the manual runbook deployment in namespace `default`.

Setup creates the connector before its final link readiness check. While waiting,
it prints the link status when it changes and at least every ten seconds. A
timeout includes the router log command for the selected namespace.

Run `bash setup-saas-connector-ubuntu.sh --help` for all options. See
[OPERATIONS.md](OPERATIONS.md) for checks and troubleshooting.
