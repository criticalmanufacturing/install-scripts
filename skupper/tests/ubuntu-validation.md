# Ubuntu validation record

Validated on 20 October 2026 in the development workspace:

- Bash syntax and ShellCheck 0.9.0, severity style: pass.
- 24 hermetic Python tests: pass, including the Unix ownership/symlink test.
- Snapshot test passes with a permissive file-creation mask; destination is 0600.
- Official Linux amd64 CLI executed: version `2.2.3`; generated Connector format
  matches the script's structured checks.
- Official release archives downloaded and SHA256 checked for both supported
  architectures:

| Architecture | SHA256 |
| --- | --- |
| amd64 | `9eb77dab5f2659becaca53364a38df38746b1850788d2652ef2084fcc3b325ab` |
| arm64 | `447de7721bd1f6f54c918c951dff5e7d3c660660dea7848cf269bb9cf0df6fa1` |

The arm64 CLI was not executed. Upstream source reviewed at Skupper tag `2.2.3`,
commit `bbf5c63b45c6ff7a19022693e420ee48835ce971`: rootless container API,
host networking, restart policy, controller user service, namespace reload,
resource status, and apply behavior.

**Not run:** full Ubuntu 24.04/26.04 VM provisioning on either architecture,
privileged hosts-file replacement, real rootless Podman/systemd startup,
application traffic through the VM, logout, reboot, and VM failure recovery.
This workspace has no disposable full VM or KVM device. These remain release
acceptance requirements in [acceptance.md](acceptance.md).

Tests use fake PEM fixtures and a filesystem-backed CLI double. They do not
prove certificate validity, successful container startup, or end-to-end traffic.
