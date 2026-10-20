# Disposable live acceptance

Run only against disposable VMs, clusters, and test applications. Supply deployment
values through environment variables; use distinct client IDs/routing keys and
private credential files. Never use production credentials as fixtures.

The hermetic tests do not replace these checks. Record OS, architecture, package
versions, CLI/controller/router versions, commands, and pass/fail in the PR or
release validation record. Mark unavailable checks as **not run**.

## Ubuntu VM matrix

Test fresh Ubuntu 24.04 and 26.04 LTS on amd64 and arm64 with a direct nonroot
login, local storage, subordinate IDs, and a real systemd user session.

1. Prepare the cloud site and a disposable TCP echo or HTTP application reachable
   from the VM. Generate a unique Link/Secret bundle; transfer with mode 600.
2. Run dry-run with Python/PyYAML installed. Confirm no packages, services, hosts,
   persistent resources, or network probes change. Invalid IPs, ports, names,
   unsupported OS, and unsafe link files must fail clearly.
3. Run setup. Verify Site/Link readiness, configured Connector, rootless containers,
   hosts mapping, enabled socket/controller/restart service, and lingering.
4. From a cloud client pod, send a real application request to the Listener Service.
   Compare response and authentication/TLS behavior with the expected test response.
5. Rerun identically: no duplicate resources/hosts entries or unnecessary router
   replacement. Change application port/IP under the same connector name: new
   connections must reach the new target; no extra connector is created.
6. Change the cloud IP to another address serving the same test endpoint. Verify
   updated VM/router hosts mappings, reconnection, and expected brief interruption.
7. Log out and check traffic from a separate client. Reboot the VM; before logging
   back in, verify the same application request succeeds. Then inspect enabled
   services, restart policy, and logs.
8. Block cloud and application ports separately. Supply invalid/expired test link
   credentials. Each setup must fail with a bounded stage-specific error. Restore
   prerequisites and rerun with the same names to verify recovery.
9. Interrupt a controlled router refresh. Verify controller recovery and rerun.
   Confirm unrelated hosts aliases and unrelated account resources are preserved.

## Kubernetes scenarios

Use two disposable clusters (or isolated sites) with existing Traefik and explicit
contexts. Follow the Kubernetes scripts' own test instructions when those PRs are
available.

- Install controllers only with the explicit flag. Test compatible controller
  reuse, missing permissions/CRDs, overlapping controllers, wrong versions, and
  an unrelated existing Site. No incompatible controller/CRD should be replaced.
- Bootstrap the cloud Listener before a Connector exists. It must become configured
  without a matching-connector deadlock. Validate protected output, stable reruns,
  distinct client credentials, and public endpoint rewriting.
- Link the second cluster and expose its test target. Check Site, Link, configured
  Connector, matching Listener, target probe, and a cloud application response.
- With an IP override, deliberately publish conflicting DNS for the cloud hostname.
  Verify the supplied IP is used and Traefik SNI/mTLS still work. Confirm the proxy
  rejects other hosts/ports, including requests from disallowed pods when the CNI
  enforces NetworkPolicy. Repeat after proxy/IP changes.
- Test malformed/extra-resource link bundles, BOM/CRLF files, missing TLS material,
  invalid credentials, blocked ports, conflicting owners, and partial applies.
- Delete only the disposable test resources and clusters. Verify temporary probe
  workloads and credential files are removed; retain only redacted evidence.
