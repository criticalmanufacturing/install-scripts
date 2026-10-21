# SaaS Connector Ubuntu validation record

Updated 21 October 2026 for the simplified Bash installer.

Checks in the development workspace:

- Bash syntax and ShellCheck for the installer and shell tests.
- Required input prompts, including a script streamed into Bash with answers
  read from a separate terminal.
- Option defaults, invalid ports, missing option values, and unknown options.
- Site name defaults to the machine hostname; cloud hostname is inferred from
  the Link endpoint, including quoted hosts and Windows line endings. Explicit
  options override these defaults; a missing Link hostname gets a clear error.
- Isolated setup/retry flow and connector updates, with host-changing commands
  replaced. No forced router reload or Python invocation.
- Exported manual setup values survive initialization, options override exports,
  and the namespace defaults to `default`, matching the manual commands.
- A Pending link does not block connector creation. The final link check shows
  progress; timeout diagnostics identify the selected namespace's router.
- Unreachable application and empty/Pending link status fail clearly.
- Real Skupper 2.2.3 CLI: site creation, Link/Secret imports, repeated import,
  connector creation, and connector host/port updates in isolated local state.

These are development checks, not evidence of a live installation. The imported
credentials in the CLI test are synthetic and are never used to establish TLS.

**Not run:** full Ubuntu VM provisioning, privileged hosts-file changes,
rootless Podman/systemd startup, real cloud links, application traffic,
logout/reboot recovery, and arm64 CLI execution. See [acceptance.md](acceptance.md).
