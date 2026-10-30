# CM Cloud Bridge public installer

These instructions apply to this folder and its descendants. Preserve the simple
customer installation flow and the existing security and retry guarantees.

## Ownership and scope

- `install.sh` is the public customer entrypoint for Native Ubuntu, Podman on
  Ubuntu, and Helm on an existing Kubernetes or OpenShift cluster. It does not
  provision a server or cluster. Ubuntu modes delegate to the published Ubuntu
  installers; Helm does not install workstation tools.
- `README.md` is the customer guide. `app-values.example.yaml` shows the settings
  Critical Manufacturing prepares before sending them to the customer.
- `tests/test_helm_install.sh` contains offline installer tests with mocked tools
  and a real controlling terminal for piped execution.
- `tests/test_install_modes.py` covers mode selection and Ubuntu delegation with
  synthetic downloads and mocked tools. Python is only a test dependency.
- Connector implementation, Helm chart sources, and artifact publishing are
  maintained separately. Do not copy them into this public installer folder.
- Use CM Cloud Bridge product terminology in public scripts, messages, examples,
  and documentation. Keep internal implementation details and infrastructure out
  of this folder's public files.

## Customer experience

- Keep installation to supplied files plus one command:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/cm-cloud-bridge/install.sh | bash
  ```

- Offer Native Ubuntu, Podman on Ubuntu, and Helm in the terminal menu;
  `--mode native|podman|helm` skips that menu. Preserve piped execution for all modes.
- Ubuntu modes default to release `1.0.0`; `--version X.Y.Z` pins the numeric
  connector release. Download the appropriate published script and `SHA256SUMS`
  from `https://criticalmanufacturing.io/repository/tools/cm-cloud-bridge-<version>/latest/`.
  Verify its checksum before execution. The version is pinned by package name;
  do not treat the storage segment `latest` as permission to select another release.
- Helm defaults to the latest stable chart release; `--version` is an optional
  explicit pin. Resolve once and reuse the downloaded package for validation and
  installation. Display the resolved version; do not use a mutable image `latest`
  tag or silently fall back after a failed lookup/download.
- Customers receive private `link.yaml` and the minimum application settings:
  connector name, address and port. `app-values.yaml` is optional for more specific
  configuration. Use an existing settings file; if it is missing, prompt for the
  three values through the terminal in every mode. Preserve full YAML handling
  for Helm files and the supplied scalar handling for Ubuntu files. Keep generated
  Helm values private and temporary; never overwrite or create the customer's
  missing settings file. Reject empty/unreadable existing files and stop on EOF
  before cluster mutations. Do not ask customers to edit files for basic setup.
  Registry credentials are requested only by Helm when access requires authentication.
- Keep the guide short: save files, run the supplied command, and contact Critical
  Manufacturing to confirm an application request. State workstation prerequisites
  and mode-specific prerequisites. Ubuntu 24.04/26.04 amd64/arm64 installations
  run as the normal login user with sudo and systemd; they require neither Helm
  nor kubectl. Explain that a first native build can take several minutes.
- Keep defaults and documented flags consistent with `install.sh`. Preserve the
  mode, version, connector identity, and namespace on retries and upgrades; Helm
  also retains its release name. A different identity can create an additional
  installation.
- Helm uses release `cm-cloud-bridge` by default. Explain the brief traffic
  interruption on upgrades, and preserve the selected release and namespace.
- Ask for the Kubernetes namespace before checking its permissions. An empty
  answer selects `default`; explicit `--namespace` uses that value without asking.
  Validate the answer and stop on EOF before cluster mutations.
- Explain actionable failures in plain language. Never report success after a
  failed operation. Installation readiness does not prove an application request
  completed through the cloud connection.
- Retain a private `cm-cloud-bridge-install-*.log` with normal terminal output and
  the final exit status on success or failure, and print its path after output
  capture completes. Prefer the current folder, then the temporary folder. Help
  must not create a log; missing logging tools must not hide installation errors.

## Installer contracts

- Keep Bash execution compatible with downloaded content on stdin. Read prompts
  from `/dev/tty`, hide token input, and reject a missing terminal when a required
  prompt cannot be completed. Helm requires terminal confirmation before mutation.
- Keep installation inside a function defined completely before its invocation,
  so a truncated function body cannot start installation while being downloaded.
- Common flags are `--mode`, `--values`, `--link-file`, and `--version`.
  Ubuntu flags are `--connector-name`, `--app-ip`, `--app-port`, `--site-name`,
  `--namespace`, `--routing-key`, `--cloud-host`, `--cloud-ip`, and `--timeout`;
  Helm supports `--namespace` and `--release`. Preserve mode-specific validation
  and reject incompatible options before mutation.
- Ubuntu modes must validate arguments, supplied settings and Link files, and
  downloaded script integrity before delegation. The published installer validates
  the host and remaining inputs. Run as the login user and leave privileged setup,
  service ownership, and idempotence to that installer. Do not copy or reimplement
  backend installation logic here.
- For Helm, validate arguments, supplied files, tools, cluster access,
  authentication, chart download, and chart rendering before changing resources.
- Capture the selected Kubernetes context once, show it for explicit confirmation,
  and pass that context to every subsequent cluster operation.
- Support users restricted to a precreated namespace. Do not require a
  cluster-scoped namespace read or namespace creation permission. Attempt creation
  only when allowed, accept `AlreadyExists`, and propagate other errors.
- Preserve `helm upgrade --install` with the same release and namespace, the
  resolved chart version, readiness waiting, and a bounded timeout.
- Keep authenticated chart access and Kubernetes image pull credentials distinct.
  The customer chart is an OCI artifact under
  `oci://criticalmanufacturing.io/criticalmanufacturing/charts/cm-cloud-bridge`.
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
- Keep downloaded Ubuntu scripts and checksum files temporary and remove them on
  exit, including failed verification or delegation. Never print private settings
  or connection file contents; do not evaluate supplied settings as shell code.
- Installation logs must be mode `0600` and remain outside temporary credential
  directories. Never append tokens, encoded authentication, rendered Secrets,
  or private Link contents. Keep the installer's failure status and terminal
  prompt behavior when capturing output; tell customers to keep logs private.
- Tell customers that Ubuntu retains private connection material on the server,
  while Helm stores credentials in Kubernetes and Helm release history; temporary
  workstation cleanup does not remove stored credentials.

## Validation and reporting

Run relevant checks from the repository root when changing shell behavior:

```bash
bash -n cm-cloud-bridge/install.sh
bash -n cm-cloud-bridge/tests/test_helm_install.sh
shellcheck -S style cm-cloud-bridge/install.sh cm-cloud-bridge/tests/test_helm_install.sh
bash cm-cloud-bridge/tests/test_helm_install.sh
python3 cm-cloud-bridge/tests/test_install_modes.py
python3 cm-cloud-bridge/tests/test_install_logs.py
```

- The terminal tests require Linux and Python 3; Python is a test dependency, not
  an installer requirement. Preserve tests for piped mode selection, explicit
  modes, Ubuntu checksum validation and delegation, cancellation, validation
  before mutation, namespace restrictions, retries, failure propagation,
  credential privacy, and cleanup when changing those behaviors.
- For documentation-only changes, verify the command, defaults, prerequisites, and
  stated behavior against the script; do not run a live customer installation.
- Report checks actually run and their limits. Offline tests do not verify registry
  availability, chart contents, a real Ubuntu installation, live cluster readiness,
  or the application connection. The documented `main` installer URL becomes
  available after the public pull request is merged; do not claim otherwise.
