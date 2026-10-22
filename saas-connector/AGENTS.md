# SaaS Connector public installer

These instructions apply to this folder and its descendants. Preserve the simple
customer installation flow and the existing security and retry guarantees.

## Ownership and scope

- `install.sh` is the public customer entrypoint for an existing Kubernetes or
  OpenShift cluster; it does not provision a cluster or install workstation tools.
- `README.md` is the customer guide. `app-values.example.yaml` shows the settings
  Critical Manufacturing prepares before sending them to the customer.
- `tests/test_helm_install.sh` contains offline installer tests with mocked tools
  and a real controlling terminal for piped execution.
- Connector implementation, Helm chart sources, and artifact publishing are
  maintained separately. Do not copy them into this public installer folder.
- Use SaaS Connector product terminology in public scripts, messages, examples,
  and documentation. Keep internal implementation details and infrastructure out
  of this folder's public files.

## Customer experience

- Keep installation to supplied files plus one command:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/saas-connector/install.sh | bash
  ```

- Default to the latest stable chart release; `--version` is an optional explicit
  pin. Resolve once and reuse the downloaded package for validation and installation.
  Display the resolved version; do not use a mutable image `latest` tag or silently
  fall back after a failed lookup/download.
- Customers receive completed `app-values.yaml`, private `link.yaml`, and registry
  credentials. Do not ask them to design settings or edit the supplied files as
  part of the normal installation flow.
- Keep the guide short: save files, run the supplied command, and contact Critical
  Manufacturing to confirm an application request. State workstation prerequisites
  and required cluster access without introducing unrelated deployment choices.
- Keep defaults and documented flags consistent with `install.sh`. Preserve the
  release and namespace on retries and upgrades; a different identity can create
  an additional installation.
- Explain actionable failures in plain language. Never report success after a
  failed operation. Helm readiness confirms installation; it does not prove an
  application request completed through the cloud connection.

## Installer contracts

- Keep Bash execution compatible with downloaded content on stdin. Read prompts
  from `/dev/tty`, hide token input, and reject a missing terminal before mutation.
- Keep installation inside a function defined completely before its invocation,
  so a truncated function body cannot start installation while being downloaded.
- Validate arguments, supplied files, tools, cluster access, authentication, chart
  download, and chart rendering before changing cluster resources.
- Capture the selected Kubernetes context once, show it for explicit confirmation,
  and pass that context to every subsequent cluster operation.
- Support users restricted to a precreated namespace. Do not require a
  cluster-scoped namespace read or namespace creation permission. Attempt creation
  only when allowed, accept `AlreadyExists`, and propagate other errors.
- Preserve `helm upgrade --install` with the same release and namespace, the
  resolved chart version, readiness waiting, and a bounded timeout.
- Keep authenticated chart access and Kubernetes image pull credentials distinct.
  The customer chart is an OCI artifact under
  `oci://criticalmanufacturing.io/criticalmanufacturing/charts/saas-connector`.
- Preserve the hidden `--registry HOST[:PORT]` testing override; keep it out of
  help and customer instructions. Default to `criticalmanufacturing.io`, and use
  the selected registry for the chart, matching image, and credentials without
  falling back to another registry. Anonymous access must use isolated credentials
  and clear image pull secret references; prompt for credentials when required.

## Private data

- Never commit real customer values, connection files, tokens, rendered manifests,
  Secret contents, or installation output containing credentials. Use synthetic
  fixtures only; the example settings file must remain credential-free.
- Disable shell tracing before handling private inputs. Pass registry tokens over
  stdin, never command arguments, URLs, diagnostics, or support instructions.
- Use isolated temporary registry configuration with restrictive file permissions;
  do not modify the customer's existing Helm/Docker login or native keychain.
- Clean temporary authentication files on success and failure. Discard rendered
  manifests and keep private Helm output out of ordinary terminal output.
- Tell customers that connection credentials remain in Kubernetes and Helm release
  history; temporary workstation cleanup does not remove those stored credentials.

## Validation and reporting

Run relevant checks from the repository root when changing shell behavior:

```bash
bash -n saas-connector/install.sh
bash -n saas-connector/tests/test_helm_install.sh
shellcheck -S style saas-connector/install.sh saas-connector/tests/test_helm_install.sh
bash saas-connector/tests/test_helm_install.sh
```

- The terminal tests require Linux and Python 3; Python is a test dependency, not
  an installer requirement. Preserve tests for piped prompts, cancellation,
  validation before mutation, namespace restrictions, retries, failure propagation,
  credential privacy, and cleanup when changing those behaviors.
- For documentation-only changes, verify the command, defaults, prerequisites, and
  stated behavior against the script; do not run a live customer installation.
- Report checks actually run and their limits. Offline tests do not verify registry
  availability, chart contents, live cluster readiness, or the application connection.
