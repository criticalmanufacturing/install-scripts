---
name: helm-dependency-examples
description: Create, update or review this repository's MES dependency Helm charts and installation examples, including validation, lifecycle hooks, application checks and storage maintenance.
---

# Helm dependency examples

Keep installation and ordinary upgrade correctness in the charts so administrators can use Helm directly. Keep the wizard, prerequisite guidance and connection-file export optional.

## Repository layout and compatibility

- `platform/v11.3/install.sh` and `platform/v12.0/install.sh` each contain the installer functions, component selection and version-specific prompts and layouts.
- Each version keeps its Helm library in `charts/common`. Application charts use a local dependency and committed lock files; generated `charts/*/charts/` directories are ignored.
- Each application chart has `values.schema.json`; the version-level schema validates proposed wizard/non-interactive values. Historical release inspection uses `read_values --historical` so legacy settings can still be migrated.
- Preserve product invariants: 11.3 uses Kafka 3.8's fixed KRaft quorum, standalone ClickHouse and RustFS, and RabbitMQ classic priority queues. Do not import v12's ClickHouse HA or distributed-storage assumptions into 11.3. Check current version defaults before changing images or layouts.
- Keep shell and template files LF on Git for Windows.

## Choose the native mechanism

| Responsibility | Mechanism |
| --- | --- |
| Types, enums, ranges and required values | Chart JSON schemas |
| Cross-field rules and retained application identity | Template `required`/`fail`, with live lookups where needed |
| Supported Kubernetes versions | `Chart.yaml` `kubeVersion`, when constrained |
| Startup, health and readiness | Kubernetes probes and Helm wait/timeout options |
| Repeatable release setup | Idempotent install/upgrade hook Jobs |
| Application connectivity and permissions | `helm.sh/hook: test`, explicitly invoked by `helm test` |
| Component selection | Small explicit list of independent releases, or dependency conditions for an umbrella chart |
| Connection instructions | `NOTES.txt`, Secret references and optional local export |

Apply schemas to the effective merged values for direct Helm and wrapper use. Keep wizard choices aligned with schemas without duplicating correctness checks in Bash. The temporary values reader delegates YAML merging to Helm; it is not a substitute for chart validation. Share suitable existing functions/helpers before adding another implementation.

Verify flags against the supported Helm majors. Hook Jobs already block on completion; ordinary Jobs need the appropriate Helm waiting options. Progress reporting must not decide release readiness independently of Helm.

## Lifecycle and application checks

Templates render before hooks: a pre-install hook cannot populate data needed by `lookup` during that same render. With Helm waiting enabled, post-install hooks run after workloads are ready; avoid a workload dependency on setup that cannot run until that workload is ready. Hook weights do not order independent releases.

Bound setup retries and deadlines. Make Jobs safe to rerun. Normally use `before-hook-creation,hook-succeeded` cleanup so failed Jobs remain available for diagnosis until retry. Hook resources and their side effects need explicit cleanup; release rollback does not undo arbitrary setup effects.

Use service endpoints, application credentials and certificate verification in Helm checks. Exercise meaningful operations: Kafka produce/consume, ClickHouse writes/queries, RabbitMQ publish/consume and S3 object operations. Match component CLI versions and supported layouts. Clean up temporary resources on failure as well as success, including exact object versions in versioned S3 buckets. Authentication values must survive configuration/SQL escaping unchanged.

Document `helm test` separately from installation. It does not run automatically, gate an earlier installation, or roll back a release when it fails. Use a suitable blocking lifecycle hook when a check must gate installation itself.

## Explicit storage maintenance

Ordinary upgrades must not silently expand PVCs or remove controllers. The existing `--resize-storage` operation in each version's `install.sh` is an explicit exception: it uses server-side preflight, private controller manifests and documented manual recovery using `kubectl`/`oc`. Read the relevant version README before changing this path. Use the existing Helm and Kubernetes CLIs rather than adding Python or extra JSON/YAML tools for storage maintenance.

Account for partial expansion, failed upgrades, interruption of the installer process, and manual recovery using saved StatefulSet YAML and `kubectl`/`oc create`. Preserve existing controllers and validate recovery namespaces. PVC expansion cannot be reversed by rollback. Independent releases do not form one transaction. Keep concurrency restrictions and failure/recovery instructions explicit; do not move broad cluster mutations into hooks merely to remove Bash.

## Verification

Run strict lint and representative TLS/platform/component renders, including invalid inputs that must fail through direct Helm. Check historical-to-current value reading when changing schemas. Exercise meaningful failure paths for custom maintenance logic without touching a live cluster by default.

When an authorized disposable cluster is available, verify fresh installation, rerun, upgrade and Helm checks, including credential stability and persistent-data invariants. Report separately which checks ran locally, which ran on Kubernetes/OpenShift, and what remains unverified.

References: [Helm schemas](https://helm.sh/docs/topics/charts/#schema-files), [hooks](https://helm.sh/docs/topics/charts_hooks/), [chart tests](https://helm.sh/docs/topics/chart_tests/), and the matching [Helm command reference](https://helm.sh/docs/helm/helm_upgrade/) for each supported major.
