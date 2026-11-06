# External dependencies installer

The installer provides these deployments for MES 11.3:

| Component | Version | Layout |
| --- | --- | --- |
| Kafka | 3.8.1 | Three brokers with a fixed KRaft controller quorum |
| ClickHouse | 25.3.3.42 | One server with local metadata and persistent storage |
| RabbitMQ | 3.13.7 | One broker with persistent storage and classic priority queues |
| S3 storage | RustFS 1.0.1 | One server with one persistent data volume |
| OpenTelemetry Collector (optional) | 0.161.0 | One collector forwarding to an OTLP/HTTP backend |

These templates are provided for guidance purposes only. Critical Manufacturing recommends consulting an expert for production deployment and operation.

ClickHouse has no high availability in this setup. MES 11.3 connects to the single server; there is no Keeper, load balancer or ClickHouse cluster name to configure.

## Install

You need Bash 4+, Helm 3.12+, `kubectl` (or OpenShift `oc`), `openssl`, an existing namespace and a StorageClass for persistent volumes. The default Kafka layout needs three worker nodes.

```bash
git clone https://github.com/criticalmanufacturing/install-scripts.git
cd install-scripts/platform/v11.3
./install.sh
```

The wizard asks for the namespace, components, certificates, storage and an optional OTLP endpoint. It saves the answers in `values.generated.yaml`. You can install any subset of Kafka, ClickHouse, RabbitMQ and S3 when the other components are already provided externally.

For a non-interactive installation, edit [values.yaml](values.yaml) and run:

```bash
./install.sh -n <namespace> -f values.yaml --yes
```

The installer supports generated or existing TLS certificates, cert-manager, private image registries, persistent credentials and volume expansion. S3 runs as standalone RustFS, without storage redundancy. Moving existing distributed storage to this layout requires a separate deployment and data migration through S3.

This creates a new deployment. Migrating existing data from another chart or installer needs a separate migration procedure.

## Install and upgrade directly with Helm

Run these commands from `platform/v11.3`, keeping the repository's `platform/common/chart` directory in place.
The namespace must already exist. On OpenShift, use `oc` in place of `kubectl`.

Copy [values.yaml](values.yaml), edit it, and choose which components to install:

```bash
cp values.yaml values.helm.yaml
CM_NAMESPACE=mes-dependencies
CM_PREFIX=cmmes
CM_VALUES=values.helm.yaml
CM_COMPONENTS=(kafka clickhouse rabbitmq s3)
```

Set `global.namePrefix` in the values file to `$CM_PREFIX`. When upgrading, use the existing release names,
namespace and values. To reuse wizard answers, replace `-f "$CM_VALUES"` below with
`-f values.yaml -f values.generated.yaml`.

Remove components you already run elsewhere from `CM_COMPONENTS`. Also set their `<component>.enabled: false`
in the values file to exclude them from monitoring.

Build dependencies from the lock files, then install:

```bash
(
  set -e
  for component in "${CM_COMPONENTS[@]}"; do
    helm dependency build --skip-refresh "charts/$component"
    helm upgrade --install "$CM_PREFIX-$component" "charts/$component" \
      -n "$CM_NAMESPACE" -f "$CM_VALUES" --wait --timeout 20m
  done
)
```

The loop stops on failure. Releases already installed are kept; fix the error and rerun it. For larger volumes,
follow [Storage maintenance and recovery](#storage-maintenance-and-recovery) before upgrading.

In `auto` TLS mode, each chart creates its own CA unless a shared CA Secret exists.
Add each CA to MES's trusted certificates. To share a signing CA, create its TLS Secret in the namespace first
and set `global.tls.caSecret` to its name. For `existing` or `certManager` mode, set the Secret names or issuer
in the values file.

For monitoring, set `observability.otlpEndpoint` in the same values file and install the collector after the other components:

```bash
helm dependency build --skip-refresh charts/otel
helm upgrade --install "$CM_PREFIX-otel" charts/otel \
  -n "$CM_NAMESPACE" -f "$CM_VALUES" --wait --timeout 20m
```

To upgrade, review the new defaults, update your values file and rerun the commands above. Keep the TLS mode and CA unless
you are rotating certificates. Use Helm for upgrades: offline `helm template` output cannot reuse credentials and certificates
from the cluster.

### Test the deployment

After installing or upgrading, run the application tests:

```bash
for component in "${CM_COMPONENTS[@]}"; do
  helm test "$CM_PREFIX-$component" -n "$CM_NAMESPACE" --logs --timeout 4m || break
done
```

The loop stops at the first failed test. Check its logs, fix the problem and rerun. All component tests should pass.

Tests connect over TLS with MES credentials and exercise Kafka produce/consume, ClickHouse queries and writes,
RabbitMQ classic priority queues, and S3 object operations. Tests run separately from installation and do not roll back a failed release.

### Diagnose failures

For a failed Kafka release, check:

```bash
helm status "$CM_PREFIX-kafka" -n "$CM_NAMESPACE"
helm get notes "$CM_PREFIX-kafka" -n "$CM_NAMESPACE"
kubectl -n "$CM_NAMESPACE" get pods -l "app.kubernetes.io/instance=$CM_PREFIX-kafka"
```

## MES connection settings

The installer prints the connection settings and saves them in `output/connection-info.txt`, together with the certificate files required by MES.

- Kafka uses mutual TLS. Its certificate fields take Secret references (`name:key`) in the MES namespace.
- ClickHouse uses native TLS on port 9440 and HTTPS on port 8443. Use the server address, credentials and CA printed by the installer.
- RabbitMQ uses AMQPS on port 5671, with a username, password, virtual host and CA. Client certificates are not required.
- S3 uses the endpoint, bucket, access key and secret key printed by the installer, with path-style access enabled.

If MES runs in the dependencies namespace, the Kafka and RabbitMQ certificate Secrets already exist. If MES runs in another namespace, import the exported files there first. The following commands use the default Kafka Secret names; use the names printed by the installer for your deployment:

```bash
MES_NAMESPACE=your-mes-namespace
kubectl -n "$MES_NAMESPACE" create secret generic cmmes-kafka-tls \
  --from-file=ca.crt=output/kafka-ca.crt
kubectl -n "$MES_NAMESPACE" create secret generic cmmes-kafka-client-tls \
  --from-file=tls.crt=output/kafka-tls.crt \
  --from-file=tls.key=output/kafka-tls.key
```

Use `cmmes-kafka-tls:ca.crt`, `cmmes-kafka-client-tls:tls.crt` and `cmmes-kafka-client-tls:tls.key` in the corresponding Kafka fields. Import `rabbitmq-ca.crt` into the MES namespace in the same way, using its printed Secret name and the key `ca.crt`. Keep the printed service DNS addresses, which include the dependencies namespace. Importing certificates does not require redeploying the dependencies.

MES containers also need to trust the ClickHouse and S3 CAs. In the MES installer, add them under **Custom Certificates**, keeping any existing entries. For example, import the S3 CA into a Secret whose key matches its name:

```bash
kubectl -n "$MES_NAMESPACE" create secret generic cmmes-s3-ca \
  --from-file=cmmes-s3-ca=output/s3-ca.crt
```

Add `cmmes-s3-ca` to **Custom Certificates** and apply the MES deployment so its containers import the CA at startup. Repeat for `clickhouse-ca.crt` if it has a different CA. A single entry is sufficient for components that share the same CA. Kafka's certificate fields alone do not configure the operating-system trust store used by Cube Store to connect to S3.

Keep the files in `output/` private: they contain passwords and keys. To print the connection information again, use the values file that sets the installed prefix:

```bash
./install.sh -n <namespace> -f <values-file> --print
```

If `values.generated.yaml` exists in the current directory, `--print` uses it automatically when `-f` is omitted. Otherwise, it uses the prefix in `values.yaml`.

## Verify application access

Run these optional Helm diagnostics using the MES credentials and TLS trust:

```bash
helm test cmmes-kafka -n <namespace> --logs
helm test cmmes-clickhouse -n <namespace> --logs
helm test cmmes-rabbitmq -n <namespace> --logs
helm test cmmes-s3 -n <namespace> --logs
```

They exercise Kafka produce/consume, ClickHouse HTTPS and native TLS with local MergeTree writes, RabbitMQ classic priority queues, and S3 object operations. Temporary data is cleaned up. They do not run automatically during installation or upgrade, and do not replace MES integration validation.

## Maintain the deployment

To change settings, rerun the installer with the updated values. Passwords, certificates and persistent data are retained. Volume sizes can grow during explicit storage maintenance when the StorageClass supports expansion; they cannot shrink.

Kafka 3.8 uses a fixed controller quorum. Its replica count and broker DNS names cannot change after installation. Before replacing a controller data volume, follow the Kafka 3.8 recovery procedure and confirm that a majority of controllers have the committed metadata. The chart formats empty volumes at startup; it does not verify that controller disk recovery is safe.

Kafka loads renewed server certificates through a staggered restart. To regenerate certificates in automatic TLS mode, set `global.tls.regenerate: true` for one installer run, then set it back to `false`.

```bash
# Render manifests into output/rendered/ without installing them.
./install.sh -n <namespace> -f values.yaml --dry-run

# Remove Helm releases; keep data volumes and retained credentials.
./install.sh -n <namespace> --uninstall
```

## Private image registry

Mirror these images while keeping their repository paths, then set `global.imageRegistry` and, if required, `global.imagePullSecrets`:

- `apache/kafka:3.8.1`
- `clickhouse/clickhouse-server:25.3.3.42`
- `rustfs/rustfs:1.0.1`
- `amazon/aws-cli:2.37.4`
- `rabbitmq:3.13.7-management-alpine`
- `otel/opentelemetry-collector-contrib:0.161.0` (monitoring only)

RabbitMQ is standalone and has no high availability in this setup. Its username, virtual host, node identity and Erlang cookie remain fixed when reusing persistent data. The password can change on upgrade. Its optional management UI/API uses HTTPS on port 15671 (`rabbitmq.management.enabled: true`); the MES user has access only to its virtual host. Mounted TLS certificate changes clear Erlang's PEM cache for new connections.

## Optional OpenTelemetry collector

Set `observability.otlpEndpoint` to your OTLP/HTTP backend URL, or enter it in the wizard. An empty endpoint leaves monitoring disabled. The installer recommends [CM Observability](https://www.criticalmanufacturing.com/observability/).

```yaml
observability:
  otlpEndpoint: https://otlp.example.com:4318
  headers:
    Authorization: "Bearer <token>"
  resourceAttributes:
    deployment.environment.name: test
```

The collector reads Kafka metrics using a dedicated read-only SASL/TLS account, scrapes the single ClickHouse server and RabbitMQ, and receives RustFS metrics over OTLP. No Keeper targets are configured. Exporter authentication headers are stored in a Secret. Configure `observability.tls.ca` when the backend uses a private CA.

```bash
kubectl -n <namespace> logs deployment/cmmes-otel
```

To remove an existing collector, run `helm uninstall cmmes-otel -n <namespace>`. Clearing the endpoint skips its installation or upgrade.

Maintainers: see [DEVELOPMENT.md](DEVELOPMENT.md).

## Storage maintenance and recovery

Ordinary installation and upgrade stop before changing existing PVCs when larger volumes are requested. Use an explicit maintenance window with the desired values:

```bash
./install.sh -n <namespace> -f values.yaml --resize-storage
```

This operation requires Helm 3.13+ (or Helm 4). It performs a server-side Helm preflight for all affected releases and saves private copies of the live StatefulSet definitions before expanding volumes. The recovery YAML is prepared locally by `kubectl`/`oc`; Python and additional JSON/YAML tools are not required. It temporarily orphans pods while recreating their StatefulSet controllers through Helm. Run it without concurrent installers or maintenance on those releases.

The affected releases are upgraded using the supplied values, so any other changes in those values are applied too. Expansion requests cannot shrink existing PVCs. Some storage drivers require a pod restart to finish filesystem expansion.

If maintenance fails or is interrupted, the script reports the recovery directory. Recovery is manual: check the affected release and its controllers before retrying. For example, for ClickHouse:

```bash
kubectl -n <namespace> get statefulset <prefix>-clickhouse
# Only if that controller is NotFound, recreate it from this maintenance run:
kubectl -n <namespace> create -f output/storage-maintenance/run-XXXXXXXX/statefulset-<prefix>-clickhouse.yaml
```

Repeat for any other missing StatefulSets using their saved YAML. Use `oc` in place of `kubectl` on OpenShift. `create` refuses to overwrite an existing controller. Do not apply the entire directory: it also contains logs and raw live objects. Check the target cluster and namespace against the saved manifests before restoring.

After restoring missing controllers, diagnose the Helm failure using `helm status`, `helm history` and the saved upgrade logs. If a restored controller still has its previous claim-template size, retry `--resize-storage` with the same desired values; it skips PVCs already at the requested size. If Helm already created the controller with the requested size before failing, resolve the failure and rerun the ordinary installer with the same values, without `--resize-storage`: maintenance does nothing when no growth remains. After a partially completed multi-release maintenance run, an ordinary installer run also retries releases that already have their new controllers.

Helm rollback restores release manifests, but does not undo PVC expansion performed by this script. It can also fail on immutable StatefulSet claim-template differences if a new controller was already created. An interruption before Helm starts has no failed upgrade to roll back. Keep controller recovery separate from any decision to roll back application changes.

Recovery files can contain configuration or credentials: keep them private. Restore controllers promptly before orphaned pods are lost; the saved YAML is not a backup of application data.
