# Development notes: CM MES v12 dependency charts

This document is for maintainers of the charts. Administrators should read [README.md](README.md).

## Goals

- Production-ready, highly available deployments of the three mandatory CM MES v12 external
  dependencies: **Kafka 4.x**, **ClickHouse 26.3 LTS** and **S3 storage** (RustFS, or an existing Ceph RGW).
- Aimed at IT administrators with little Kubernetes experience. `./install.sh` asks the questions
  and prints the values to type into the CM MES installer.
- **A single code path** for vanilla Kubernetes / RKE2 / k3s, OpenShift, AKS / EKS / GKE:
  - no operators and no CRDs of our own. Only namespace-scoped resources, so namespace admin rights are enough.
  - ClusterIP services only (CM MES runs in the same cluster).
  - OpenShift is supported through `common.podSecurityContext`, which omits UID/GID/fsGroup there.
- The admin can install any subset of the components ("pick and choose").

## Layout

```
platform/v12.0/
  install.sh        interactive / non-interactive installer (bash)
  values.yaml       the single configuration file that admins edit (all sections)
  charts/common     library chart shared by all charts (see "common helpers")
  charts/kafka      Kafka (KRaft, combined controller+broker StatefulSet)
  charts/clickhouse ClickHouse server StatefulSet + ClickHouse Keeper StatefulSet
  charts/s3         RustFS distributed StatefulSet, or an ObjectBucketClaim for Ceph RGW
  charts/otel       optional OpenTelemetry collector, pushing metrics to an OTLP/HTTP endpoint
```

Every chart depends on `common` through `repository: file://../common`. Run
`helm dependency update --skip-refresh charts/<name>` before rendering (install.sh does this). The
vendored `charts/<name>/charts/` folders are git-ignored; `Chart.lock` files are committed.

Pod templates use `common.podLabels`, which has no chart version, so a chart bump alone doesn't
restart pods. Every other resource uses `common.labels`.

## Releases, names and values

| Chart | Release name | Main resource names |
|---|---|---|
| kafka | `<prefix>-kafka` | `<prefix>-kafka` (bootstrap Service, StatefulSet), `<prefix>-kafka-headless` |
| clickhouse | `<prefix>-clickhouse` | `<prefix>-clickhouse`, `<prefix>-clickhouse-headless`, `<prefix>-keeper`, `<prefix>-keeper-headless` |
| s3 | `<prefix>-s3` | `<prefix>-s3` (S3 API Service), `<prefix>-s3-headless` |
| otel | `<prefix>-otel` | `<prefix>-otel` (Deployment, Service with OTLP 4317/4318) |

`<prefix>` = `global.namePrefix` (default `cmmes`). Resource names use `common.fullname`, never the release name.

**One values file for all charts.** `install.sh` passes the same values file to every release.
Each chart reads `global` plus **its own top-level section** (`kafka`, `clickhouse`, `s3`,
`observability`), and ignores the others. The only exception is `otel`, which also reads the
other sections to find what to monitor. Each chart's own `values.yaml` holds complete, commented
defaults for `global` and its section, so it also works on its own:
`helm install cmmes-kafka charts/kafka -n <ns> -f values.yaml`.

`<section>.enabled` is only used by install.sh to decide which releases to install. Charts ignore it.

### Keys set by install.sh (contract)

```yaml
global:
  namePrefix: cmmes
  storageClass: ""                  # "" = cluster default
  imageRegistry: ""                 # e.g. registry.example.com/mirror  (prefixes every image repository)
  imagePullSecrets: []              # list of Secret names
  platform: auto                    # auto | openshift | kubernetes
  clusterDomain: cluster.local
  podAntiAffinity: hard             # hard | soft
  nodeSelector: {}
  tolerations: []
  tls:
    mode: auto                      # auto | existing | certManager
    caSecret: ""                    # default "<prefix>-ca", created by install.sh in auto mode
    regenerate: false
    validityDays: 1825
    certManager: {issuerName: "", issuerKind: ClusterIssuer, issuerGroup: cert-manager.io}
kafka:
  enabled: true
  replicas: 3
  auth:
    method: sasl                    # sasl (SASL_SSL Plain) | mtls
  tls:
    existingSecret: ""              # tls.mode=existing: broker certificate Secret
    existingClientSecret: ""        # tls.mode=existing + mtls: MES client certificate Secret
  storage: {size: 50Gi, storageClass: ""}
clickhouse:
  enabled: true
  replicas: 2
  tls: {existingSecret: ""}
  storage: {size: 100Gi, storageClass: ""}
  keeper:
    replicas: 3
    storage: {size: 10Gi, storageClass: ""}
s3:
  enabled: true
  provider: rustfs                  # rustfs | rgw
  bucket: cm-mes
  rustfs:
    replicas: 3
    volumesPerPod: 2
    tls: {existingSecret: ""}
    storage: {size: 100Gi, storageClass: ""}
  rgw:
    storageClass: ocs-storagecluster-ceph-rgw
observability:
  otlpEndpoint: ""                  # empty = no otel release is installed
  headers: {}                       # e.g. {Authorization: "Bearer ..."}
  tls: {insecureSkipVerify: false, ca: ""}
  resourceAttributes: {}
```

Charts may add more keys to their own section (resources, image, tuning, and so on), always with defaults.

## Conventions every chart must follow

- **Images** (`<section>.image.{repository,tag,pullPolicy}`): the repository has no registry host,
  e.g. `apache/kafka`. Always render with `common.image` and add `common.imagePullSecrets` to every pod.
  Pinned versions:
  - `apache/kafka:4.3.1`
  - `clickhouse/clickhouse-server:26.3.35.3`
  - `clickhouse/clickhouse-keeper:26.3.35.3`
  - `rustfs/rustfs:1.0.0`
  - `amazon/aws-cli:2.37.4`
  - `otel/opentelemetry-collector-contrib:0.161.0`

  Don't add other images unless it's unavoidable (air-gapped customers must mirror every one).
- **Security**: `common.podSecurityContext` (pass the image's numeric UID/GID) and
  `common.containerSecurityContext` on every pod/container, including init containers, Jobs and test pods.
  - No privileged containers, no hostPath, no root.
  - Images must work with an arbitrary UID (OpenShift). Write only to volumes: PVCs or `emptyDir`
    for config, tmp and logs. Don't rely on the image entrypoint writing into the image filesystem.
- **HA**:
  - `common.affinity` on every stateful workload (one pod per node, hard by default).
  - `common.pdb` with `maxUnavailable: 1`.
  - `podManagementPolicy: Parallel` where the software needs peers to form a quorum.
  - Readiness, liveness and startup probes.
- **Storage**: `volumeClaimTemplates` with `common.storageClass`. Never delete PVCs from templates.
- **Scheduling**: `common.scheduling` (nodeSelector/tolerations, component values win over global).
- **TLS**: all client traffic is encrypted.
  - Each chart includes `common.tls.caSecret` once, passing its main component.
  - Server/client certificates are created with `common.tls.certificate`.
  - The Secret to mount is named with `common.tls.secretName`.
  - Every TLS Secret has `tls.crt`, `tls.key` and `ca.crt`.
  - Kafka keys must be PKCS#8 (`pkcs8: true`). In `existing` mode, convert the admin's key with
    `common.tls.pkcs8` into a derived Secret if needed, or document the requirement.
  - Server certificate SANs must include the short, `<svc>.<ns>`, `<svc>.<ns>.svc` and full FQDN
    names of the Services, plus a wildcard for the headless Service (per-pod names).
- **Passwords** are generated with `common.secretValue`, so they're stable across `helm upgrade`
  and identical in every template. An explicit value in values.yaml always wins. Secrets whose
  values are configured in CM MES or protect data (users/passwords, KRaft identity, CA) carry
  `helm.sh/resource-policy: keep`, so an uninstall + reinstall keeps them.
- **Certificate renewal never restarts pods**: no TLS checksum annotations. Kafka (maintenance.sh),
  ClickHouse, Keeper and RustFS reload renewed certificates from the mounted Secret.
- **Startup order**: a pod that needs a peer at startup waits for it in its start script instead
  of crashing (e.g. ClickHouse waits for a Keeper quorum). Helm 4 `--wait` fails the release on
  the first container crash.
- **XML** (ClickHouse/Keeper config): comments must not contain `--`, which makes the file invalid.
  ClickHouse only reads users.d at startup and crash-loops on invalid XML, so render and check
  that every `*.xml` key is well-formed.
- **Connection Secret**: every chart (except otel) renders exactly one `common.connectionSecret` with
  the fields using the CM MES installer labels:

  | Component | order | Fields (label: value) |
  |---|---|---|
  | Kafka | 10 | Bootstrap Servers (all brokers, `host:port`, comma separated), Authentication Method (`SASL_SSL Plain` / `mTLS`), Kafka Username, Kafka Password (SASL), Ssl Certificate Authority (`kafka-ca.crt`), Ssl Certificate / Ssl Key (mTLS: `kafka-tls.crt` / `kafka-tls.key`), Validate certificates (`true`) |
  | ClickHouse | 20 | Address, TCP Port (native TLS, 9440), HTTP Port (HTTPS, 8443), Username, Password, Encrypt (`true`), Certificate Authority (`clickhouse-ca.crt`), Automatically provision additional users (`true`) |
  | S3 | 30 | Address, Bucket Name, AccessKey Id, Secret Access Key, Use Path Style (`true`), Certificate Authority (`s3-ca.crt`) |

  Files that the admin must upload (e.g. the Kafka mTLS client certificate and key) are listed in
  the `files` argument and saved by install.sh as `<component>-<key>`. The Kafka mTLS files are
  therefore `kafka-tls.crt` / `kafka-tls.key`.

  Exceptions:
  - `s3.provider=rgw` renders no connection Secret. The values only exist once the ObjectBucketClaim
    is bound, so install.sh builds the S3 block from the OBC's ConfigMap/Secret (`BUCKET_HOST`,
    `BUCKET_PORT`, `BUCKET_NAME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). On port 443/8443 it
    uses https, with the CA from the `openshift-service-ca.crt` ConfigMap.
  - `otel` has no connection Secret and no `helm test` (it has no MES login).
- **`helm test`**: every chart ships `templates/tests/*` pods that prove that a client can connect
  with the MES credentials over TLS. They use the component's own image (or aws-cli for S3).
- **NOTES.txt**: short. It says how to read the connection Secret and points to install.sh.
- Everything must pass `helm lint --strict`, `helm template` with Helm 3 and Helm 4, and
  `kubeconform -strict` (with `-ignore-missing-schemas` for cert-manager/ObjectBucketClaim), for
  every supported option combination, both with `--api-versions security.openshift.io/v1` and without.

## Monitoring contract (used by charts/otel)

The OTel collector is installed only when `observability.otlpEndpoint` is set. It collects metrics
and sends them over OTLP/HTTP to that endpoint (CM Observability).

- **ClickHouse and Keeper** expose Prometheus metrics on port **9363** at `/metrics` (plain HTTP,
  in-cluster) on every pod. Pods are addressed as `<prefix>-clickhouse-<i>.<prefix>-clickhouse-headless`
  and `<prefix>-keeper-<i>.<prefix>-keeper-headless`. The collector builds static targets from the
  replica counts.
- **Kafka** provides the Secret `<prefix>-kafka-monitoring` with only these keys:
  - `bootstrap` (`host:port,...`) and `protocol` (`SASL_SSL` or `SSL`)
  - `username` and `password` when `protocol` is `SASL_SSL`, for a `monitor` principal with
    read-only Describe/DescribeConfigs ACLs on the cluster, topics and groups

  Certificates are NOT copied into it. The otel chart mounts them straight from the Kafka TLS
  Secrets, using `common.tls.secretName` on the shared values, so renewals are picked up:
  - CA (`ca.crt`): component `kafka`, existingSecret `kafka.tls.existingSecret`
    (i.e. `<prefix>-kafka-tls` in auto/certManager mode)
  - mTLS monitor certificate (`tls.crt`/`tls.key`): component `kafka-monitor`, existingSecret
    `kafka.tls.existingMonitorSecret` (i.e. `<prefix>-kafka-monitor-tls`)

  The collector uses the `kafka_metrics` receiver and reloads its client certificate hourly. A CA
  change restarts it on upgrade (checksum annotation). With mTLS in `existing` TLS mode and no
  `kafka.tls.existingMonitorSecret`, the monitor principal falls back to SASL_SSL on the INTERNAL
  listener (9092). The otel chart follows the same rule.
- **RustFS** exports its telemetry itself over OTLP to the local collector
  (`http://<prefix>-otel.<ns>.svc.<clusterDomain>:4318`) when `observability.otlpEndpoint` is set.
  The collector always exposes an OTLP receiver on 4317/4318 for this.
