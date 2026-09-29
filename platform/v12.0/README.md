# CM MES v12: external dependencies installer

This folder installs the three external systems that Critical Manufacturing MES v12 needs into a
Kubernetes or OpenShift cluster, set up for production (highly available, encrypted):

| Component | What is installed | Survives the loss of |
|---|---|---|
| **Kafka 4.3** | 3 Kafka servers (KRaft, no ZooKeeper) | 1 node |
| **ClickHouse 26.3 LTS** | 2 ClickHouse servers (replicated) + 3 ClickHouse Keeper | 1 node |
| **S3 storage** | RustFS 1.0: 3 servers × 2 disks (erasure coded), **or** a bucket on your existing Ceph RGW (e.g. OpenShift Data Foundation) | 1 node |

You can install all three or only the ones you need. At the end, the installer prints the values to
type into the **CM MES installer** (addresses, users, passwords) and saves the certificate files it needs.

## Before you start

**Cluster**
- Kubernetes 1.27+ (vanilla, RKE2, k3s, AKS, EKS, GKE) or OpenShift 4.14+.
- **At least 3 worker nodes.** Each component spreads its servers one per node. With the defaults and
  all components, plan for about **8 vCPU and 32 GiB of RAM per node**.
- A StorageClass that can create volumes (`kubectl get storageclass`). With the defaults you need
  about 1 TiB in total: Kafka 3×50 GiB, ClickHouse 2×100 GiB + 3×10 GiB, RustFS 6×100 GiB.
- A namespace that **already exists**, where you can create resources. Cluster-admin rights are not
  needed: everything is created inside that namespace.

**Your computer** (Linux, macOS, or Windows with Git Bash or WSL)
- `bash`, [`kubectl`](https://kubernetes.io/docs/tasks/tools/) connected to the cluster (on OpenShift,
  `oc` is enough: the installer uses it when `kubectl` isn't installed),
  [`helm`](https://helm.sh/docs/intro/install/) 3.12 or newer, and `openssl`.
- Check it works with `kubectl get nodes` and `helm version`.

## Install

```bash
git clone https://github.com/criticalmanufacturing/install-scripts.git
cd install-scripts/platform/v12.0
./install.sh
```

The installer checks your cluster, then asks you, step by step:

1. which namespace to use, and it confirms the cluster you're connected to
2. which components to install
3. how certificates are created: **automatically** (recommended), from your own certificates, or by cert-manager
4. how MES logs in to Kafka: username/password (SASL_SSL Plain, recommended) or client certificates (mTLS)
5. for S3: install RustFS, or use your existing Ceph RGW (only offered when it's detected)
6. storage sizes, and an optional private image registry
7. an optional monitoring endpoint (see [Monitoring](#monitoring))

Your answers are saved in `values.generated.yaml`. Installing takes about 5 to 15 minutes.

### What you get

The installer prints one block per component and saves everything in `./output/`:

```
[Kafka]
Bootstrap Servers                         : cmmes-kafka-0.cmmes-kafka-headless.<namespace>.svc.cluster.local:9093,...
Authentication Method                     : SASL_SSL Plain
Kafka Username                            : mes
Kafka Password                            : ********
Ssl Certificate Authority                 : kafka-ca.crt
...
[ClickHouse]
Address                                   : cmmes-clickhouse.<namespace>.svc.cluster.local
TCP Port                                  : 9440
HTTP Port                                 : 8443
Cluster Name                              : default
...
[S3]
Address                                   : cmmes-s3.<namespace>.svc.cluster.local
Bucket Name                               : cm-mes
...
```

- **ClickHouse Cluster Name**: always fill it in the CM MES installer. Without it, CM MES creates
  each table on only one of the two ClickHouse servers, and it isn't highly available.
- `output/connection-info.txt`: all the values above. It contains passwords, so keep it safe.
- `output/*-ca.crt`: the certificate authorities. Add them in the CM MES installer where it asks for
  certificates (or enable "skip certificate validation", which isn't recommended for production).
- `output/kafka-tls.crt` and `kafka-tls.key`: only when Kafka uses client certificates (mTLS).

To print them again later: `./install.sh -n <namespace> --print`.

### Check the installation

```bash
helm test cmmes-kafka -n <namespace>
helm test cmmes-clickhouse -n <namespace>
helm test cmmes-s3 -n <namespace>
```

Each test logs in with the MES credentials and writes and reads data. For ClickHouse, the test
checks that the data is on both servers.

## Install without questions

Edit [`values.yaml`](values.yaml), which has a comment for every setting, or reuse a
`values.generated.yaml`, then run:

```bash
./install.sh -n <namespace> -f values.yaml --yes
```

`--dry-run` only writes the Kubernetes manifests to `./output/rendered/` so you can review them.

## Options explained

**Certificates** (`global.tls.mode`)
- `auto` (default): the installer creates a private certificate authority (`cmmes-ca` Secret) and
  certificates for each component, valid for 5 years. You add `*-ca.crt` in the CM MES installer.
- `existing`: use your own certificates. Create one Secret per component with `tls.crt`, `tls.key`
  and `ca.crt`. The certificate names (SANs) must cover the service names listed in `NOTES` after
  install; see `charts/<component>/values.yaml`.
- `certManager`: cert-manager (installed by your cluster admin) issues and renews the certificates
  from the issuer you name.

**Ceph RGW instead of RustFS** (`s3.provider: rgw`): on OpenShift Data Foundation (StorageClass
`ocs-storagecluster-ceph-rgw`) or Rook-Ceph, the installer requests a bucket (ObjectBucketClaim)
and prints its address and keys. The bucket name gets a random suffix, e.g. `cm-mes-1a2b...`.

**Private registry / air-gapped clusters** (`global.imageRegistry`, `global.imagePullSecrets`).
Mirror these images, keeping their names:
`apache/kafka:4.3.1`, `clickhouse/clickhouse-server:26.3.35.3`, `clickhouse/clickhouse-keeper:26.3.35.3`,
`rustfs/rustfs:1.0.0`, `amazon/aws-cli:2.37.4`, and `otel/opentelemetry-collector-contrib:0.161.0` (monitoring only).

**Advanced settings** (CPU, memory, tuning) are documented in `charts/<name>/values.yaml`. Copy a
key into the same section of your values file to change it.

## Monitoring

If you use the [CM Observability](https://www.criticalmanufacturing.com/observability/) service (recommended
for production), give the installer its OTLP/HTTP endpoint. A small OpenTelemetry collector then sends
Kafka, ClickHouse and RustFS metrics there. If you leave it empty, nothing is installed for monitoring.

## Day-to-day operations

- **Change a setting or upgrade**: edit your values file and run `./install.sh -n <namespace> -f <file> --yes` again,
  or run `./install.sh` and reuse your saved answers. Passwords and certificates are kept.
  Disks can only **grow**, and only if the StorageClass allows expansion. The installer resizes them
  for you after asking. It refuses to shrink a disk or change its StorageClass.
- **Node maintenance**: drain one node at a time. The installer creates PodDisruptionBudgets, so
  Kubernetes won't stop more than one server of a component at once.
- **Certificates**: in `auto` mode they're valid for 5 years (the CA for 10). To renew, set
  `global.tls.regenerate: true` once, re-run the installer, then set it back to `false`. The CA
  doesn't change, so nothing changes in MES. Renewed certificates (including cert-manager's) are
  picked up automatically without downtime. If Kafka can't reload, it restarts one server at a time.
- **Scaling**: the defaults (3 Kafka, 2 ClickHouse + 3 Keeper, 3×2 RustFS disks) are the tested layout.
  Adding Kafka servers later needs extra Kafka steps (see `charts/kafka/templates/NOTES.txt`), and the
  RustFS layout can't be changed after the first install.
- **Uninstall**: `./install.sh -n <namespace> --uninstall`. **Data volumes are kept** on purpose, so
  a reinstall finds the data again. The uninstaller lists them and prints the command that deletes
  them, if you want the data gone too (irreversible).

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Pods stay `Pending`, "didn't match pod anti-affinity" | fewer than 3 usable nodes | add nodes, or set `global.podAntiAffinity: soft` (not highly available) |
| Pods stay `Pending`, "Insufficient cpu/memory" | nodes too small | add capacity, or lower `resources` in your values file |
| PVCs stay `Pending` | no default StorageClass, or the wrong one | set `global.storageClass` (see `kubectl get storageclass`) |
| `ImagePullBackOff` | no internet access from the cluster | set `global.imageRegistry` to your mirror |
| RustFS won't start: "same disk" | the StorageClass puts both disks of a server on the same disk (e.g. local-path) | use a real storage backend; for test clusters only: `s3.rustfs.allowSharedDisks: true` |

The installer prints the relevant pod events when something fails and keeps logs in `output/logs/`.
After fixing the cause, run the installer again with the same options: it continues where it stopped.

To look inside ClickHouse (no password needed from inside the pod):
`kubectl -n <namespace> exec -it cmmes-clickhouse-0 -- clickhouse-client`.

**Known issue (RustFS 1.0.0):** after RustFS servers restart, the logs may repeat
`Heal object recovery failed` for the internal object `.rustfs.sys/scanner/durable-dirty-producer-replay.json`.
It doesn't affect your data or MES. It's a RustFS bug ([rustfs#7997](https://github.com/rustfs/rustfs/issues/7997)),
fixed in RustFS 1.0.1: this installer will move to 1.0.1 once it's released as stable.
Maintainers: see [DEVELOPMENT.md](DEVELOPMENT.md).
