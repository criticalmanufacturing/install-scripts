# Maintaining the dependency installer

The starting point is `../v12.0`. Common helpers and the installer workflow are reused; the following differences are specific to MES 11.3.

## Kafka

- Image: `apache/kafka:3.8.1`.
- Static KRaft: `controller.quorum.voters`, persisted in the retained KRaft Secret with the cluster ID.
- Formatting uses `kafka-storage.sh format --cluster-id ... --config ...`; Kafka 4.x initial-controller and dynamic voter-management commands are removed.
- The controller listener is not included in `advertised.listeners`.
- Log4j properties replace the Kafka 4.x Log4j2 YAML configuration.
- Replica count and broker DNS names are checked against the retained quorum before an upgrade.
- Server certificate renewal uses staggered restarts. Dynamic controller certificate reload is not assumed.
- MES authentication, TLS modes and ACL provisioning follow the v12 implementation.

## ClickHouse

- Image: `clickhouse/clickhouse-server:25.3.3.42`.
- Exactly one server. Values for Keeper, load balancing, cluster naming and replication are rejected.
- Access metadata is stored under `/var/lib/clickhouse/access/` on the data volume. No Keeper or replicated access storage is deployed.
- The Service points directly to the server. Connection output contains no cluster name.

## S3

- Image: `rustfs/rustfs:1.0.1`.
- Exactly one server and one persistent data volume. `RUSTFS_VOLUMES` is a local path, with no erasure coding or distributed endpoints.
- Distributed layouts and Ceph RGW settings are rejected. Existing distributed data must be migrated through S3 to a separate deployment.
- TLS, retained credentials, bucket creation and the dedicated MES user are retained.

## RabbitMQ

- Official image: `rabbitmq:3.13.7-management-alpine`, matching the Product 11.3 manifest.
- One broker and one PVC, without clustering or queue mirroring. Keep classic queues: MES uses priority queues and explicitly requests the classic type.
- Definitions are imported at startup from a Secret. Credentials and Erlang cookie are retained; username, virtual host and node identity cannot change with retained data.
- AMQPS only on 5671. The optional management plugin uses HTTPS on 15671. The Prometheus plugin is enabled only when an OTLP endpoint is configured.
- TLS uses the shared chart helpers. A background check clears Erlang's PEM cache when mounted certificates change.

## Monitoring

The optional collector is based on v12 and is installed only when `observability.otlpEndpoint` is set. It uses Kafka 3.8.1 with a read-only SASL_SSL monitoring account, scrapes ClickHouse 25.3 at port 9363 without Keeper targets, scrapes RabbitMQ at port 15692, and receives metrics from standalone RustFS over OTLP. Monitoring credentials, metric endpoints and RustFS export are disabled by default.

Kafka monitor ACLs grant only Describe and DescribeConfigs. Collector backend headers live in a Secret and use environment references in the ConfigMap. The image remains pinned to the v12 collector version, 0.161.0.

## Layout

`install.sh` passes one values file to every chart. Each chart reads `global` and its component section. The optional collector also reads the enabled component sections.

Each application chart depends on the library chart at `file://../common`, version `11.3.0`. Regenerate its `Chart.lock` with:

```bash
for chart in kafka clickhouse rabbitmq s3 otel; do
  helm dependency update --skip-refresh "charts/$chart"
done
```

Keep support statements consistent with README.md: these are guidance templates. Preserve the v12 directory and older release configurations when adapting this version.

`s3.setup.resources` configures the bucket setup Job. Its containers run sequentially and use the same resource settings.
