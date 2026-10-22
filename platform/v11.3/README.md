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

Keep the files in `output/` private: they contain passwords and keys. Print the connection information again with:

```bash
./install.sh -n <namespace> --print
```

## Maintain the deployment

To change settings, rerun the installer with the updated values. Passwords, certificates and persistent data are retained. Volume sizes can grow when the StorageClass supports expansion; they cannot shrink.

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
