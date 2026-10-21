# SaaS Connector Ubuntu VM acceptance

Use disposable Ubuntu 24.04 and 26.04 LTS VMs, amd64 and arm64, with a normal
sudo user, a real systemd login session, and test credentials.

1. Prepare the cloud Skupper site, Listener, and a TCP/HTTP application reachable
   from the VM. Generate and securely transfer a Link/Secret YAML file.
2. Run setup without options. Answer each prompt. Confirm the site name defaults
   to the VM hostname and the cloud hostname comes from the Link YAML. Test
   explicit `--site-name` and `--cloud-host` overrides. Test both existing DNS and an
   optional cloud hostname/IP override. Confirm no Python/PyYAML/jq is installed
   or invoked by setup. Repeat using exported setup variables; options must
   override exports, and the default namespace must be `default`.
3. Verify Site and Link reach Ready, the Connector targets the supplied address,
   and the link file has mode 600. Confirm the router's hostname resolution.
4. Send an application request from the cloud Listener Service and verify its
   response, including application authentication where applicable.
5. Rerun using the original site/namespace/connector names. Check there are no
   duplicate resources or hosts entries. Change the application port; verify
   the existing connector is updated and new traffic reaches the new target.
6. Check a partial installation left by the previous script using its original
   generated site/namespace name. Setup must not force a router reload.
7. Log out, then reboot. Verify application traffic from the cloud before logging
   into the VM again. Inspect lingering and enabled user services.
8. Test an unreadable link file, invalid port, conflicting hosts entry, unavailable
   application, and blocked cloud endpoint. Expect clear failures. Restore the
   prerequisite and retry with the same names. While the link is Pending, the
   connector must still be created; the final wait must show progress and timeout
   with the correct namespace's router log command.
9. Review any existing router's hosts snapshot before changing its cloud IP.
   Test manual recovery separately; automated container recreation is outside
   this script.

Record versions and pass/fail results. The isolated Bash tests do not prove
Podman startup, mutual TLS, logout/reboot recovery, or real application traffic.

## Connector image and Helm chart

1. Build the image and run `bash saas-connector/tests/test_container.sh` first. The test
   must prove actual HTTP traffic across a generated mutual-TLS link, not merely
   CLI exit codes or a configured Site status.
2. Run `bash saas-connector/tests/test_helm.sh`. Confirm missing inputs and invalid ports
   fail at render time, cloud IP overrides produce the expected hostAliases,
   credentials changes trigger rollout, and separate release names stay isolated.
3. The cluster owner tests OpenShift: deploy under the default restricted SCC with no
   extra grants. Verify the assigned UID is in the namespace range, generated state
   is writable, the root filesystem and credential mount are read-only, and no
   service-account API token is mounted. Send an application request from the
   cloud through the authenticated link to the target.
4. Repeat on an arm64 node. Exercise both pod DNS and optional hostAliases, a
   Kubernetes Service target and an external application IP, pod replacement,
   target updates, credential rotation, and a second independent Helm release.
5. Interrupt the cloud endpoint and the backend separately. The router should
   stay alive and reconnect when the cloud returns; backend failure should make
   readiness fail. No custom Python helpers or OpenSSL checks are required.

Record OpenShift/Kubernetes versions and pass/fail results. The current container
validation evidence is in [container-validation.md](container-validation.md).
