#!/usr/bin/env bash
# =============================================================================
# Critical Manufacturing MES v12 - installer of the external dependencies
#   Kafka, ClickHouse, S3 storage (RustFS or Ceph RGW) and an optional
#   OpenTelemetry collector.
#
# Usage:
#   ./install.sh                                   interactive wizard (recommended)
#   ./install.sh -n <namespace> -f <values.yaml>   non-interactive (asks to confirm)
#   ./install.sh -n <namespace> -f <values.yaml> --yes
#   ./install.sh ... --dry-run                     render to ./output/rendered/, install nothing
#   ./install.sh -n <namespace> --print            print the connection information again
#   ./install.sh -n <namespace> --uninstall        remove the releases (data volumes are kept)
#   ./install.sh -h                                help
#
# Requirements: bash >= 4, kubectl, helm >= 3.12 (Helm 4 is fine), openssl, and
# the usual coreutils (sed, awk, grep, sort, base64). Works on Linux, macOS and
# Git Bash on Windows. No yq/jq/python needed.
#
# Environment overrides: KUBECTL (e.g. "oc"), HELM, NO_COLOR.
# =============================================================================
set -euo pipefail

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: install.sh needs bash 4 or newer (this is bash ${BASH_VERSION:-unknown})." >&2
  echo "       On macOS: 'brew install bash', then run: bash ./install.sh" >&2
  exit 1
fi

# shellcheck source=../lib/install-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/install-common.sh"
# shellcheck source=../lib/storage-maintenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/storage-maintenance.sh"

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${SCRIPT_DIR}/charts"
BASE_VALUES_FILE="${SCRIPT_DIR}/values.yaml"
OUTPUT_DIR="${PWD}/output"
OUT_SHOW="./output"            # how OUTPUT_DIR is shown to the user
GENERATED_VALUES="values.generated.yaml"
if [[ -z "${KUBECTL:-}" ]]; then
  # OpenShift admins often only have 'oc', which accepts every kubectl command we use.
  if ! command -v kubectl >/dev/null 2>&1 && command -v oc >/dev/null 2>&1; then KUBECTL=oc; else KUBECTL=kubectl; fi
fi
HELM="${HELM:-helm}"
MIN_HELM_MAJOR=3
MIN_HELM_MINOR=12
CM_OBSERVABILITY_URL="https://www.criticalmanufacturing.com/observability/"
COMPONENTS=(kafka clickhouse s3)
CONNECTION_LABEL="cmf.criticalmanufacturing.com/connection=true"
ANN="cmf\\.criticalmanufacturing\\.com"   # annotation prefix, escaped for kubectl jsonpath

# ----------------------------------------------------------------------------
# Options and state
# ----------------------------------------------------------------------------
ACTION="install"          # install | uninstall | print
NAMESPACE=""
USER_VALUES=""
DRY_RUN=false
HELM_TIMEOUT="20m"
INTERACTIVE=false

CLUSTER_OK=false
IS_OPENSHIFT=false
HAS_CERT_MANAGER=false
HAS_OBC=false
NODE_COUNT="unknown"
DEFAULT_STORAGE_CLASS=""
declare -a STORAGE_CLASSES=()   # "name|provisioner|default(true/empty)"
declare -a RGW_CLASSES=()       # bucket StorageClass names (Ceph RGW)
declare -A EFFECTIVE_VALUES=()        # effective values (read through helm)
declare -A VALUE_OVERRIDES=()         # wizard overrides: path -> YAML value
declare -A WIZARD_ANSWERS=()          # wizard answers: path -> plain value
declare -A BASE_VALUES=()             # values.yaml alone (the wizard writes only differences from it)
declare -a VALUES_FILES=()      # values files passed to every release
declare -a SAVED_FILES=()       # files written to ./output by print_connection_info
VALUES_DISPLAY=""

cleanup() { if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi; }
trap cleanup EXIT

usage() {
  cat <<EOF
Critical Manufacturing MES v12 - external dependencies installer

Installs Kafka, ClickHouse and S3 storage (and optionally an OpenTelemetry collector)
into an existing Kubernetes / OpenShift namespace, then prints the values to type
into the CM MES installer.

Usage:
  ./install.sh [options]

Without -f, an interactive wizard asks all the questions and writes your answers to
${GENERATED_VALUES}. With -f, the given values file is used (on top of values.yaml).

Options:
  -n, --namespace <ns>   Namespace to install into (must already exist).
  -f, --values <file>    Values file (e.g. ${GENERATED_VALUES}, or an edited copy of values.yaml).
  -y, --yes              Do not ask for confirmation.
      --dry-run          Only render the manifests into ./output/rendered/ (installs nothing).
      --print            Print the connection information of an existing installation again.
      --resize-storage   Explicit volume expansion and affected-release upgrades.
      --uninstall        Uninstall the releases. Data volumes (PVCs) are kept.
      --timeout <dur>    Time to wait for each component (default ${HELM_TIMEOUT}).
  -h, --help             Show this help.

Examples:
  ./install.sh
  ./install.sh -n mes-deps -f ${GENERATED_VALUES} --yes
  ./install.sh -n mes-deps -f values.yaml --dry-run
  ./install.sh -n mes-deps --print

Files written to ./output/: connection-info.txt, <component>-ca.crt and other
certificate files for the CM MES installer, logs/ and rendered/ (dry run).
EOF
}

# ----------------------------------------------------------------------------
# Small utilities
# ----------------------------------------------------------------------------
kc()  { "$KUBECTL" "$@"; }

is_dns_label()  { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 63 ]]; }
is_secret_name(){ [[ "$1" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && ${#1} -le 253 ]]; }
is_size()       { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?(Mi|Gi|Ti)$ ]]; }

# Absolute path of an existing file (for comparing values files).
abs_path() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

release_name() { printf '%s-%s' "${EFFECTIVE_VALUES[global.namePrefix]}" "$1"; }

component_title() {
  case "$1" in
    kafka) echo "Kafka" ;; clickhouse) echo "ClickHouse" ;; s3) echo "S3 storage" ;;
    otel) echo "OpenTelemetry collector" ;; *) echo "$1" ;;
  esac
}

# ----------------------------------------------------------------------------
# Reading values without yq: render a tiny throw-away chart with helm.
#
# Why helm and not awk: install.sh passes values.yaml AND the user's file to every
# release, so the effective value is Helm's merge of both. Letting Helm itself parse
# and merge the files gives exactly the values the charts will see (any valid YAML:
# flow maps, quoting, anchors, comments), and reports YAML syntax errors early.
# Limits: maps are returned as their sorted key names, lists as comma-separated
# items, multi-line strings with "\n"; values must not contain a newline to be
# compared. That is enough for the keys install.sh needs.
# ----------------------------------------------------------------------------
VALUE_KEYS=(
  global.namePrefix global.storageClass global.imageRegistry global.imagePullSecrets
  global.platform global.podAntiAffinity global.tls.mode global.tls.caSecret
  global.tls.certManager.issuerName global.tls.certManager.issuerKind
  kafka.enabled kafka.replicas kafka.auth.method kafka.tls.existingSecret
  kafka.tls.existingClientSecret kafka.storage.size
  clickhouse.enabled clickhouse.replicas clickhouse.tls.existingSecret clickhouse.storage.size
  clickhouse.keeper.replicas clickhouse.keeper.storage.size clickhouse.loadBalancer.enabled
  s3.enabled s3.provider s3.bucket s3.rustfs.replicas s3.rustfs.volumesPerPod
  s3.rustfs.tls.existingSecret s3.rustfs.storage.size s3.rgw.storageClass
  kafka.storage.storageClass clickhouse.storage.storageClass clickhouse.keeper.storage.storageClass
  s3.rustfs.storage.storageClass s3.rustfs.allowSharedDisks
  observability.otlpEndpoint observability.headers observability.tls.insecureSkipVerify
  observability.tls.ca observability.headers@json observability.tls.ca@json
)


enabled() { [[ "${EFFECTIVE_VALUES[$1.enabled]:-true}" == "true" ]]; }
otel_enabled() { [[ -n "${EFFECTIVE_VALUES[observability.otlpEndpoint]:-}" ]]; }


# ----------------------------------------------------------------------------
# Step 1: prerequisites
# ----------------------------------------------------------------------------



check_namespace() {
  $CLUSTER_OK || return 0
  local out
  if out="$(kc get namespace "$NAMESPACE" -o name 2>&1)"; then
    ok "Namespace '$NAMESPACE' exists"
  elif grep -Eqi 'notfound|not found' <<<"$out"; then
    die "Namespace '$NAMESPACE' does not exist. Ask your cluster administrator to create it (kubectl create namespace $NAMESPACE), then run again."
  else
    warn "Cannot check that namespace '$NAMESPACE' exists (no permission to read namespaces); continuing."
  fi
  # Everything the charts create (helm test pods included). Conditional kinds: preflight_checks.
  require_can_i create secrets configmaps services statefulsets.apps deployments.apps jobs.batch \
    poddisruptionbudgets.policy pods
  ok "You can create the needed resources in '$NAMESPACE'"
}

# require_can_i <verb> <resource>...: stops when the user may not <verb> one of them.

# ----------------------------------------------------------------------------
# Step 2: detection
# ----------------------------------------------------------------------------

detect_cluster() {
  $CLUSTER_OK || return 0
  if [[ -n "$(kc api-resources --api-group=security.openshift.io -o name 2>/dev/null | tr -d '\r')" ]]; then
    IS_OPENSHIFT=true; ok "Platform: OpenShift"
  else
    ok "Platform: Kubernetes"
  fi

  if api_group_has cert-manager.io certificates; then HAS_CERT_MANAGER=true; ok "cert-manager is installed"
  else note "cert-manager is not installed (optional)"; fi

  local out line name prov def
  STORAGE_CLASSES=(); RGW_CLASSES=(); DEFAULT_STORAGE_CLASS=""
  if out="$(kc get storageclass -o "jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.provisioner}{\"|\"}{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}{\"\\n\"}{end}" 2>/dev/null)"; then
    while IFS='|' read -r name prov def; do
      name=${name%$'\r'}; def=${def%$'\r'}
      [[ -n "$name" ]] || continue
      if [[ "$prov" == *ceph.rook.io/bucket && "$prov" != *noobaa* && "$name" != *noobaa* ]]; then
        RGW_CLASSES+=("$name"); continue
      fi
      [[ "$prov" == *noobaa* || "$prov" == *bucket* ]] && continue
      STORAGE_CLASSES+=("$name|$prov|$def")
      [[ "$def" == true ]] && DEFAULT_STORAGE_CLASS=$name
    done <<<"$out"
    if ((${#STORAGE_CLASSES[@]} == 0)); then
      warn "No StorageClass found: the data volumes cannot be created. Ask your cluster administrator."
    else
      ok "StorageClasses: $(for s in "${STORAGE_CLASSES[@]}"; do printf '%s ' "${s%%|*}"; done)${DEFAULT_STORAGE_CLASS:+(default: $DEFAULT_STORAGE_CLASS)}"
      [[ -n "$DEFAULT_STORAGE_CLASS" ]] || warn "No default StorageClass: you will have to choose one."
    fi
  else
    warn "Cannot list StorageClasses (no permission); you can still type a name."
  fi

  if api_group_has objectbucket.io objectbucketclaims; then
    HAS_OBC=true
    if ((${#RGW_CLASSES[@]} > 0)); then ok "Ceph RGW bucket StorageClasses: ${RGW_CLASSES[*]}"
    else note "ObjectBucketClaim is available but no Ceph RGW bucket StorageClass was found"; fi
  fi

  local total=0 sched=0 unsched taints
  if out="$(kc get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.spec.unschedulable}{"|"}{.spec.taints[*].effect}{"\n"}{end}' 2>/dev/null)"; then
    while IFS='|' read -r name unsched taints; do
      [[ -n "$name" ]] || continue
      total=$((total + 1))
      taints=${taints%$'\r'}
      [[ "$unsched" == true ]] && continue
      [[ "$taints" == *NoSchedule* || "$taints" == *NoExecute* ]] && continue
      sched=$((sched + 1))
    done <<<"$out"
    NODE_COUNT=$sched
    if (( sched >= 3 )); then
      ok "Schedulable worker nodes: $sched (of $total)"
    else
      warn "Only $sched schedulable worker node(s) (of $total). High availability needs at least 3 nodes:"
      warn "Kafka, ClickHouse Keeper and RustFS put one pod per node and will stay Pending."
    fi
  else
    NODE_COUNT="unknown"
    note "Cannot list nodes (no permission). Make sure the cluster has at least 3 worker nodes."
  fi
}

# ----------------------------------------------------------------------------
# Wizard (steps 3 to 9)
# ----------------------------------------------------------------------------
OVERRIDE_KEY_ORDER=(
  global.namePrefix global.storageClass global.imageRegistry global.imagePullSecrets
  global.podAntiAffinity global.tls.mode global.tls.certManager.issuerName
  global.tls.certManager.issuerKind
  kafka.enabled kafka.tls.existingSecret kafka.tls.existingClientSecret kafka.storage.size
  clickhouse.enabled clickhouse.tls.existingSecret clickhouse.storage.size clickhouse.keeper.storage.size
  s3.enabled s3.provider s3.rustfs.tls.existingSecret s3.rustfs.storage.size s3.rustfs.storage.storageClass
  s3.rustfs.allowSharedDisks s3.rgw.storageClass
  observability.otlpEndpoint observability.headers observability.tls.insecureSkipVerify observability.tls.ca
)

write_generated() {
  local file=$1
  if [[ -f "$file" ]]; then
    cp -p "$file" "$file.bak"
    note "Previous $file saved as $file.bak. Settings in it that the wizard does not ask"
    note "about (e.g. keys added by hand) are not carried over: copy them back if needed."
  fi
  (
    umask 077
    {
      printf '# Generated by install.sh on %s for namespace "%s".\n' "$(date '+%Y-%m-%d %H:%M')" "$NAMESPACE"
      printf '# Only the settings that differ from values.yaml are listed here.\n'
      printf '# Re-run the same installation with:\n#   ./install.sh -n %s -f %s\n' "$NAMESPACE" "$file"
      printf '# Keep this file private if it contains an observability token.\n\n'
      if ((${#VALUE_OVERRIDES[@]} == 0)); then printf '{}\n'; else emit_overrides; fi
    } >"$file"
  )
  ok "Answers saved to $file"
}

wizard_components() {
  heading "Step 3/8 - Components"
  note "CM MES v12 needs Kafka, ClickHouse and S3 storage. Skip one only if you already have it."
  local c ans any=false
  while true; do
    for c in "${COMPONENTS[@]}"; do
      local def=y; [[ "${EFFECTIVE_VALUES[$c.enabled]}" == false ]] && def=n
      ask_yn ans "Install $(component_title "$c")?" "$def"
      WIZARD_ANSWERS[$c.enabled]=$ans
      $ans && any=true
    done
    $any && break
    warn "Choose at least one component."
  done
}

wizard_tls() {
  heading "Step 4/8 - Certificates (TLS)"
  note "All connections are encrypted. Choose where the certificates come from:"
  local -a opts=("auto|generated automatically, signed by one CA created now (recommended)"
                 "existing|you already created Secrets with tls.crt, tls.key and ca.crt")
  $HAS_CERT_MANAGER && opts+=("certManager|issued by cert-manager (installed in this cluster)")
  local def=${EFFECTIVE_VALUES[global.tls.mode]}
  [[ "$def" == certManager ]] && ! $HAS_CERT_MANAGER && def=auto
  ask_choice "WIZARD_ANSWERS[global.tls.mode]" "Certificate mode" "$def" "${opts[@]}"
  case "${WIZARD_ANSWERS[global.tls.mode]}" in
    auto)
      note "A CA Secret '${EFFECTIVE_VALUES[global.namePrefix]}-ca' is created (RSA 4096, valid 10 years) if it does not exist."
      note "install.sh saves its certificate as <component>-ca.crt for the CM MES installer." ;;
    existing)
      note "Each Secret must have tls.crt, tls.key and ca.crt, and the certificate must be valid for the"
      note "service names (<prefix>-<component>.$NAMESPACE.svc and *.<prefix>-<component>-headless...)."
      if [[ "${WIZARD_ANSWERS[kafka.enabled]}" == true ]]; then
        ask_existing_secret kafka.tls.existingSecret "Kafka server certificate Secret"
        ask_existing_secret kafka.tls.existingClientSecret "Kafka client (CM MES, CN=mes) certificate Secret"
      fi
      [[ "${WIZARD_ANSWERS[clickhouse.enabled]}" == true ]] && ask_existing_secret clickhouse.tls.existingSecret "ClickHouse server certificate Secret"
      true ;;
    certManager)
      while true; do
        ask "WIZARD_ANSWERS[global.tls.certManager.issuerName]" "cert-manager issuer name" "${EFFECTIVE_VALUES[global.tls.certManager.issuerName]:-}"
        [[ -n "${WIZARD_ANSWERS[global.tls.certManager.issuerName]}" ]] && break
        warn "The issuer name is required."
      done
      ask_choice "WIZARD_ANSWERS[global.tls.certManager.issuerKind]" "Issuer kind" "${EFFECTIVE_VALUES[global.tls.certManager.issuerKind]:-ClusterIssuer}" \
        "ClusterIssuer|cluster-wide issuer" "Issuer|issuer in namespace $NAMESPACE"
      local kind=${WIZARD_ANSWERS[global.tls.certManager.issuerKind],,}
      if $CLUSTER_OK && ! kcn get "$kind.cert-manager.io" "${WIZARD_ANSWERS[global.tls.certManager.issuerName]}" >/dev/null 2>&1; then
        warn "Could not find $kind '${WIZARD_ANSWERS[global.tls.certManager.issuerName]}' (or no permission to read it). Check the name."
      fi ;;
  esac
}


wizard_s3() {
  [[ "${WIZARD_ANSWERS[s3.enabled]}" == true ]] || return 0
  heading "Step 5/8 - S3 storage"
  if $HAS_OBC && ((${#RGW_CLASSES[@]} > 0)); then
    note "A Ceph RGW object store was found in this cluster. You can use it instead of installing RustFS."
    ask_choice "WIZARD_ANSWERS[s3.provider]" "S3 provider" "${EFFECTIVE_VALUES[s3.provider]}" \
      "rustfs|install RustFS here, distributed over ${EFFECTIVE_VALUES[s3.rustfs.replicas]:-3} pods (recommended)" \
      "rgw|use the existing Ceph RGW (a bucket is requested with an ObjectBucketClaim)"
  else
    note "RustFS (S3 compatible) is installed, distributed over ${EFFECTIVE_VALUES[s3.rustfs.replicas]:-3} pods."
    [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]] && warn "s3.provider=rgw in values.yaml, but no Ceph RGW bucket StorageClass was found: using RustFS."
    WIZARD_ANSWERS[s3.provider]=rustfs
  fi
  if [[ "${WIZARD_ANSWERS[s3.provider]}" == rgw ]]; then
    local -a opts=() s
    local def=${RGW_CLASSES[0]}
    for s in "${RGW_CLASSES[@]}"; do opts+=("$s|"); [[ "$s" == "${EFFECTIVE_VALUES[s3.rgw.storageClass]:-}" ]] && def=$s; done
    ask_choice "WIZARD_ANSWERS[s3.rgw.storageClass]" "Bucket StorageClass" "$def" "${opts[@]}"
  elif [[ "${WIZARD_ANSWERS[global.tls.mode]}" == existing ]]; then
    ask_existing_secret s3.rustfs.tls.existingSecret "RustFS server certificate Secret"
  fi
}

# Provisioner of a StorageClass ("" = cluster default). Empty when unknown.
sc_provisioner() {
  local want=${1:-$DEFAULT_STORAGE_CLASS} s name prov isdef
  for s in ${STORAGE_CLASSES[@]+"${STORAGE_CLASSES[@]}"}; do
    IFS='|' read -r name prov isdef <<<"$s"
    [[ "$name" == "$want" ]] && { printf '%s' "$prov"; return 0; }
  done
  return 0
}

# true when a provisioner is known to put all volumes of a pod on the same device
# (RustFS then refuses to start: one disk failure would take several drives).
is_shared_disk_provisioner() {
  case "${1,,}" in
    *local-path*|*hostpath*|*host-path*|*nfs*|*cephfs*|topolvm.io|*topolvm*|*lvms*) return 0 ;;
  esac
  return 1
}

# StorageClass used by the RustFS volumes (component value, else global).
rustfs_storage_class() {
  local sc=${1-${EFFECTIVE_VALUES[s3.rustfs.storage.storageClass]:-}}
  [[ -n "$sc" ]] || sc=${2-${EFFECTIVE_VALUES[global.storageClass]:-}}
  printf '%s' "$sc"
}

wizard_rustfs_disks() {
  local sc prov choice
  WIZARD_ANSWERS[s3.rustfs.storage.storageClass]=${EFFECTIVE_VALUES[s3.rustfs.storage.storageClass]:-}
  WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]=${EFFECTIVE_VALUES[s3.rustfs.allowSharedDisks]:-false}
  while true; do
    sc="$(rustfs_storage_class "${WIZARD_ANSWERS[s3.rustfs.storage.storageClass]}" "${WIZARD_ANSWERS[global.storageClass]}")"
    prov="$(sc_provisioner "$sc")"
    if [[ -z "$prov" ]] || ! is_shared_disk_provisioner "$prov"; then return 0; fi
    [[ "${WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]}" == true ]] && return 0
    warn "StorageClass '${sc:-$DEFAULT_STORAGE_CLASS}' ($prov) usually puts both RustFS volumes of a pod on the"
    warn "same disk. RustFS refuses that: one disk failure would lose several drives at once."
    note "Use block storage that gives every volume its own disk: Ceph RBD, cloud disks (EBS, Azure Disk,"
    note "GCE PD), vSphere, Longhorn..."
    local -a opts=()
    ((${#STORAGE_CLASSES[@]} > 1)) && opts+=("other|choose another StorageClass for RustFS only")
    opts+=("allow|allow shared disks anyway (s3.rustfs.allowSharedDisks=true; NOT for production)")
    ask_choice choice "What do you want to do?" "${opts[0]%%|*}" "${opts[@]}"
    if [[ "$choice" == allow ]]; then WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]=true; return 0; fi
    local -a scs=() s name prov2 isdef
    for s in "${STORAGE_CLASSES[@]}"; do
      IFS='|' read -r name prov2 isdef <<<"$s"
      scs+=("$name|$prov2")
    done
    ask_choice "WIZARD_ANSWERS[s3.rustfs.storage.storageClass]" "StorageClass for the RustFS volumes" "${scs[0]%%|*}" "${scs[@]}"
  done
}

wizard_storage() {
  heading "Step 6/8 - Storage and images"
  local -a opts=() s
  local def="" name prov isdef
  if ((${#STORAGE_CLASSES[@]} > 0)); then
    [[ -n "$DEFAULT_STORAGE_CLASS" ]] && opts+=("|cluster default ($DEFAULT_STORAGE_CLASS)")
    for s in "${STORAGE_CLASSES[@]}"; do
      IFS='|' read -r name prov isdef <<<"$s"
      if [[ "$isdef" == true ]]; then opts+=("$name|$prov (default)"); else opts+=("$name|$prov"); fi
    done
    def=${EFFECTIVE_VALUES[global.storageClass]:-}
    [[ -z "$def" && -z "$DEFAULT_STORAGE_CLASS" ]] && def=${STORAGE_CLASSES[0]%%|*}
    note "Data volumes need a StorageClass with ReadWriteOnce volumes, ideally block storage"
    note "(Ceph RBD, cloud disks, vSphere...). NFS and CephFS are not recommended for databases."
    ask_choice "WIZARD_ANSWERS[global.storageClass]" "StorageClass for the data volumes" "$def" "${opts[@]}"
  else
    ask "WIZARD_ANSWERS[global.storageClass]" "StorageClass for the data volumes (empty = cluster default)" "${EFFECTIVE_VALUES[global.storageClass]:-}"
  fi

  if [[ "${WIZARD_ANSWERS[s3.enabled]}" == true && "${WIZARD_ANSWERS[s3.provider]}" == rustfs ]]; then wizard_rustfs_disks; fi

  note "Size of each data volume (e.g. 50Gi, 1Ti). It can be increased later (never decreased)"
  note "when the StorageClass allows expansion; use --resize-storage for existing volumes."
  [[ "${WIZARD_ANSWERS[kafka.enabled]}" == true ]] && ask_size kafka.storage.size "Kafka, per broker (x${EFFECTIVE_VALUES[kafka.replicas]:-3})" kafka data
  if [[ "${WIZARD_ANSWERS[clickhouse.enabled]}" == true ]]; then
    ask_size clickhouse.storage.size "ClickHouse, per server (x${EFFECTIVE_VALUES[clickhouse.replicas]:-2})" clickhouse data
    ask_size clickhouse.keeper.storage.size "ClickHouse Keeper, per server (x${EFFECTIVE_VALUES[clickhouse.keeper.replicas]:-3})" keeper data
  fi
  if [[ "${WIZARD_ANSWERS[s3.enabled]}" == true && "${WIZARD_ANSWERS[s3.provider]}" == rustfs ]]; then
    ask_size s3.rustfs.storage.size "RustFS, per volume (x${EFFECTIVE_VALUES[s3.rustfs.replicas]:-3} pods x ${EFFECTIVE_VALUES[s3.rustfs.volumesPerPod]:-2} volumes)" s3 data-0
  fi

  WIZARD_ANSWERS[global.podAntiAffinity]=${EFFECTIVE_VALUES[global.podAntiAffinity]}
  if [[ "$NODE_COUNT" != unknown ]] && (( NODE_COUNT < 3 )); then
    local soft
    warn "This cluster has fewer than 3 schedulable nodes."
    ask_yn soft "Allow several pods of a component on the same node (NOT highly available; test only)?" n
    $soft && WIZARD_ANSWERS[global.podAntiAffinity]=soft
  fi

  local private
  note "Air-gapped clusters pull the images from a private registry that mirrors them."
  ask_yn private "Use a private image registry?" "$([[ -n "${EFFECTIVE_VALUES[global.imageRegistry]:-}" ]] && echo y || echo n)"
  if $private; then
    local reg
    while true; do
      ask reg "Registry and path (e.g. registry.example.com/mirror)" "${EFFECTIVE_VALUES[global.imageRegistry]:-}"
      reg=${reg#http://}; reg=${reg#https://}; reg=${reg%/}
      [[ -n "$reg" && "$reg" != *" "* ]] && break
      warn "Type the registry host, optionally with a path."
    done
    WIZARD_ANSWERS[global.imageRegistry]=$reg
    ask "WIZARD_ANSWERS[global.imagePullSecrets]" "Image pull Secret name (empty = none)" "${EFFECTIVE_VALUES[global.imagePullSecrets]%%,*}"
  else
    WIZARD_ANSWERS[global.imageRegistry]=""
    WIZARD_ANSWERS[global.imagePullSecrets]=""
  fi
}

wizard_observability() {
  heading "Step 7/8 - Monitoring (optional)"
  note "An OpenTelemetry collector can send the metrics of these components to an OTLP/HTTP"
  note "endpoint, for example the CM Observability service. Leave empty to skip."
  local ep
  while true; do
    ask ep "OTLP/HTTP endpoint (e.g. https://otlp.example.com:4318)" "${EFFECTIVE_VALUES[observability.otlpEndpoint]:-}"
    [[ -z "$ep" || "$ep" =~ ^https?://[^[:space:]]+$ ]] && break
    warn "The endpoint must start with https:// (or http://)."
  done
  WIZARD_ANSWERS[observability.otlpEndpoint]=$ep
  WIZARD_ANSWERS[observability.headers]=""
  WIZARD_ANSWERS[observability.tls.ca]=""
  WIZARD_ANSWERS[observability.tls.insecureSkipVerify]=${EFFECTIVE_VALUES[observability.tls.insecureSkipVerify]:-false}
  if [[ -z "$ep" ]]; then
    warn "No monitoring will be installed. Without it, problems in Kafka, ClickHouse or S3 are"
    warn "only noticed when CM MES fails. We recommend CM Observability: $CM_OBSERVABILITY_URL"
    return 0
  fi
  local auth hname hvalue old_headers=${EFFECTIVE_VALUES[observability.headers]:-}
  ask_yn auth "Does the endpoint need an authentication header (e.g. an API token)?" "$([[ -n "$old_headers" ]] && echo y || echo n)"
  if $auth; then
    if [[ -n "$old_headers" ]]; then
      local keep
      ask_yn keep "Keep the current header(s) ($old_headers)?" y
      if $keep; then WIZARD_ANSWERS[observability.headers]=${EFFECTIVE_VALUES[observability.headers@json]}; auth=false; fi
    fi
  fi
  if $auth; then
    ask hname "Header name" "${old_headers%%,*}"
    [[ -n "$hname" ]] || hname=Authorization
    while true; do
      ask_secret hvalue "Header value (e.g. Bearer <token>; hidden)"
      [[ -n "$hvalue" ]] && break
      warn "The value cannot be empty."
    done
    WIZARD_ANSWERS[observability.headers]="{$(yaml_str "$hname"): $(yaml_str "$hvalue")}"
  fi
  if [[ "$ep" == https://* ]]; then
    local caf old_ca=${EFFECTIVE_VALUES[observability.tls.ca]:-}
    while true; do
      if [[ -n "$old_ca" ]]; then
        ask caf "File with the endpoint's CA certificate (PEM; Enter = keep the current one, '-' = none)" ""
        if [[ -z "$caf" ]]; then WIZARD_ANSWERS[observability.tls.ca]=${EFFECTIVE_VALUES[observability.tls.ca@json]}; break; fi
        [[ "$caf" == - ]] && { WIZARD_ANSWERS[observability.tls.ca]='""'; break; }
      else
        ask caf "File with the endpoint's CA certificate (PEM; empty = public CAs)" ""
        [[ -z "$caf" ]] && break
      fi
      if [[ -f "$caf" ]] && grep -q 'BEGIN CERTIFICATE' "$caf"; then
        WIZARD_ANSWERS[observability.tls.ca]="|"$'\n'"$(tr -d '\r' <"$caf")"; break
      fi
      warn "'$caf' is not a readable PEM certificate file."
    done
    local skip
    ask_yn skip "Skip the endpoint certificate validation (testing only)?" "$([[ "${WIZARD_ANSWERS[observability.tls.insecureSkipVerify]}" == true ]] && echo y || echo n)"
    WIZARD_ANSWERS[observability.tls.insecureSkipVerify]=$skip
  fi
}

run_wizard() {
  wizard_components
  wizard_tls
  wizard_s3
  wizard_storage
  wizard_observability

  # Translate the answers into overrides of values.yaml.
  VALUE_OVERRIDES=()
  local c
  for c in "${COMPONENTS[@]}"; do set_ov "$c.enabled" "${WIZARD_ANSWERS[$c.enabled]}" "${WIZARD_ANSWERS[$c.enabled]}"; done
  set_ov global.tls.mode "$(yaml_str "${WIZARD_ANSWERS[global.tls.mode]}")" "${WIZARD_ANSWERS[global.tls.mode]}"
  if [[ "${WIZARD_ANSWERS[global.tls.mode]}" == certManager ]]; then
    set_ov global.tls.certManager.issuerName "$(yaml_str "${WIZARD_ANSWERS[global.tls.certManager.issuerName]}")" "${WIZARD_ANSWERS[global.tls.certManager.issuerName]}"
    set_ov global.tls.certManager.issuerKind "$(yaml_str "${WIZARD_ANSWERS[global.tls.certManager.issuerKind]}")" "${WIZARD_ANSWERS[global.tls.certManager.issuerKind]}"
  fi
  local p
  for p in kafka.tls.existingSecret kafka.tls.existingClientSecret clickhouse.tls.existingSecret s3.rustfs.tls.existingSecret \
           s3.provider s3.rgw.storageClass kafka.storage.size clickhouse.storage.size \
           clickhouse.keeper.storage.size s3.rustfs.storage.size global.podAntiAffinity global.storageClass \
           s3.rustfs.storage.storageClass global.imageRegistry observability.otlpEndpoint; do
    [[ -n "${WIZARD_ANSWERS[$p]+x}" ]] && set_ov "$p" "$(yaml_str "${WIZARD_ANSWERS[$p]}")" "${WIZARD_ANSWERS[$p]}"
  done
  if [[ -n "${WIZARD_ANSWERS[global.imagePullSecrets]:-}" ]]; then
    set_ov global.imagePullSecrets "[$(yaml_str "${WIZARD_ANSWERS[global.imagePullSecrets]}")]" "${WIZARD_ANSWERS[global.imagePullSecrets]}"
  elif [[ -n "${BASE_VALUES[global.imagePullSecrets]:-}" && "${WIZARD_ANSWERS[global.imageRegistry]:-}" == "" ]]; then
    VALUE_OVERRIDES[global.imagePullSecrets]="[]"
  fi
  [[ -n "${WIZARD_ANSWERS[observability.headers]}" ]] && VALUE_OVERRIDES[observability.headers]=${WIZARD_ANSWERS[observability.headers]}
  [[ -n "${WIZARD_ANSWERS[observability.tls.ca]}" ]] && VALUE_OVERRIDES[observability.tls.ca]=${WIZARD_ANSWERS[observability.tls.ca]}
  set_ov observability.tls.insecureSkipVerify "${WIZARD_ANSWERS[observability.tls.insecureSkipVerify]}" "${WIZARD_ANSWERS[observability.tls.insecureSkipVerify]}"
  if [[ -n "${WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]+x}" ]]; then
    set_ov s3.rustfs.allowSharedDisks "${WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]}" "${WIZARD_ANSWERS[s3.rustfs.allowSharedDisks]}"
  fi
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
show_summary() {
  $INTERACTIVE || heading "Summary"
  local p=${EFFECTIVE_VALUES[global.namePrefix]} sc=${EFFECTIVE_VALUES[global.storageClass]:-}
  [[ -n "$sc" ]] || sc="cluster default${DEFAULT_STORAGE_CLASS:+ ($DEFAULT_STORAGE_CLASS)}"
  printf '  %-22s %s\n' "Namespace:" "$NAMESPACE" "Name prefix:" "$p" "TLS certificates:" "${EFFECTIVE_VALUES[global.tls.mode]}"
  if enabled kafka; then
    printf '  %-22s %s\n' "Kafka:" "${EFFECTIVE_VALUES[kafka.replicas]:-3} brokers, ${EFFECTIVE_VALUES[kafka.storage.size]:-?} each, CM MES logs in with a client certificate (release $p-kafka)"
  else printf '  %-22s %s\n' "Kafka:" "not installed"; fi
  if enabled clickhouse; then
    local lb="failover load balancer"
    [[ "${EFFECTIVE_VALUES[clickhouse.loadBalancer.enabled]:-true}" == false ]] && lb="no load balancer (sticky Service)"
    printf '  %-22s %s\n' "ClickHouse:" "${EFFECTIVE_VALUES[clickhouse.replicas]:-2} servers x ${EFFECTIVE_VALUES[clickhouse.storage.size]:-?}, ${EFFECTIVE_VALUES[clickhouse.keeper.replicas]:-3} keepers x ${EFFECTIVE_VALUES[clickhouse.keeper.storage.size]:-?}, $lb (release $p-clickhouse)"
  else printf '  %-22s %s\n' "ClickHouse:" "not installed"; fi
  if enabled s3; then
    if [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then
      printf '  %-22s %s\n' "S3:" "Ceph RGW bucket (StorageClass ${EFFECTIVE_VALUES[s3.rgw.storageClass]:-?}) (release $p-s3)"
    else
      printf '  %-22s %s\n' "S3:" "RustFS, ${EFFECTIVE_VALUES[s3.rustfs.replicas]:-3} pods x ${EFFECTIVE_VALUES[s3.rustfs.volumesPerPod]:-2} volumes x ${EFFECTIVE_VALUES[s3.rustfs.storage.size]:-?} (release $p-s3)"
    fi
  else printf '  %-22s %s\n' "S3:" "not installed"; fi
  if otel_enabled; then
    printf '  %-22s %s\n' "Monitoring:" "OpenTelemetry collector -> ${EFFECTIVE_VALUES[observability.otlpEndpoint]} (release $p-otel)"
  else
    printf '  %-22s %s\n' "Monitoring:" "none"
  fi
  printf '  %-22s %s\n' "StorageClass:" "$sc" "Pod spreading:" "${EFFECTIVE_VALUES[global.podAntiAffinity]}"
  [[ -n "${EFFECTIVE_VALUES[global.imageRegistry]:-}" ]] && printf '  %-22s %s\n' "Image registry:" "${EFFECTIVE_VALUES[global.imageRegistry]} (pull Secret: ${EFFECTIVE_VALUES[global.imagePullSecrets]:-none})"
  local shown=$VALUES_DISPLAY f
  if [[ -z "$shown" ]]; then
    for f in "${VALUES_FILES[@]}"; do
      f=${f#"$SCRIPT_DIR"/}
      shown+="${shown:+ + }${f#"$PWD"/}"
    done
  fi
  printf '  %-22s %s\n' "Values files:" "$shown"
  if $DRY_RUN; then printf '  %-22s %s\n' "Mode:" "dry run (render only, nothing is installed)"; fi
  true
}

# Warnings that need the cluster facts, for both the wizard and -f mode.
preflight_checks() {
  $CLUSTER_OK || return 0
  [[ "${EFFECTIVE_VALUES[global.tls.mode]}" == certManager ]] && require_can_i create certificates.cert-manager.io
  if enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then require_can_i create objectbucketclaims.objectbucket.io; fi
  if enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rustfs && "${EFFECTIVE_VALUES[s3.rustfs.allowSharedDisks]:-false}" != true ]]; then
    local rsc rprov
    rsc="$(rustfs_storage_class)"; rprov="$(sc_provisioner "$rsc")"
    if [[ -n "$rprov" ]] && is_shared_disk_provisioner "$rprov"; then
      warn "RustFS StorageClass '${rsc:-$DEFAULT_STORAGE_CLASS}' ($rprov) usually puts both volumes of a pod on one disk:"
      warn "RustFS will refuse to start. Use block storage (s3.rustfs.storage.storageClass), or for"
      warn "non-production only set s3.rustfs.allowSharedDisks: true."
    fi
  fi
  if [[ "${EFFECTIVE_VALUES[global.tls.mode]}" == certManager ]] && ! $HAS_CERT_MANAGER; then
    die "global.tls.mode=certManager, but cert-manager is not installed in this cluster."
  fi
  if enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then
    $HAS_OBC || die "s3.provider=rgw, but the ObjectBucketClaim API (objectbucket.io) is not available in this cluster."
    local found=false s
    for s in ${RGW_CLASSES[@]+"${RGW_CLASSES[@]}"}; do [[ "$s" == "${EFFECTIVE_VALUES[s3.rgw.storageClass]}" ]] && found=true; done
    $found || warn "s3.rgw.storageClass '${EFFECTIVE_VALUES[s3.rgw.storageClass]}' is not a known Ceph RGW bucket StorageClass (found: ${RGW_CLASSES[*]:-none})."
  fi
  if [[ "${EFFECTIVE_VALUES[global.tls.mode]}" == existing ]]; then
    local p
    for p in kafka.tls.existingSecret kafka.tls.existingClientSecret clickhouse.tls.existingSecret s3.rustfs.tls.existingSecret; do
      [[ -n "${EFFECTIVE_VALUES[$p]:-}" ]] && enabled "${p%%.*}" && check_tls_secret "${EFFECTIVE_VALUES[$p]}"
    done
  fi
  if [[ "$NODE_COUNT" != unknown ]] && (( NODE_COUNT < 3 )) && [[ "${EFFECTIVE_VALUES[global.podAntiAffinity]}" == hard ]]; then
    warn "Fewer than 3 schedulable nodes with global.podAntiAffinity=hard: some pods will stay Pending."
  fi
  if [[ -n "${EFFECTIVE_VALUES[global.storageClass]:-}" ]] && ((${#STORAGE_CLASSES[@]} > 0)); then
    local s found=false
    for s in "${STORAGE_CLASSES[@]}"; do [[ "${s%%|*}" == "${EFFECTIVE_VALUES[global.storageClass]}" ]] && found=true; done
    $found || warn "StorageClass '${EFFECTIVE_VALUES[global.storageClass]}' was not found in the cluster."
  elif [[ -z "${EFFECTIVE_VALUES[global.storageClass]:-}" && -z "$DEFAULT_STORAGE_CLASS" ]] && ((${#STORAGE_CLASSES[@]} > 0)); then
    warn "global.storageClass is empty and the cluster has no default StorageClass: volumes will stay Pending."
  fi
  if [[ -n "${EFFECTIVE_VALUES[global.imagePullSecrets]:-}" ]]; then
    local s
    IFS=, read -r -a _ips <<<"${EFFECTIVE_VALUES[global.imagePullSecrets]}"
    for s in "${_ips[@]}"; do
      kcn get secret "$s" >/dev/null 2>&1 || warn "Image pull Secret '$s' was not found in namespace $NAMESPACE."
    done
  fi
  true
}

# ----------------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------------

install_release() {
  local comp=$1 rel log
  rel="$(release_name "$comp")"
  local -a vargs=()
  local f
  for f in "${VALUES_FILES[@]}"; do vargs+=(-f "$f"); done
  mkdir -p "$OUTPUT_DIR/logs"
  log="$OUTPUT_DIR/logs/$rel.log"

  if $DRY_RUN; then
    local -a api=()
    $IS_OPENSHIFT && api+=(--api-versions security.openshift.io/v1)
    $HAS_CERT_MANAGER && api+=(--api-versions cert-manager.io/v1)
    $HAS_OBC && api+=(--api-versions objectbucket.io/v1alpha1)
    mkdir -p "$OUTPUT_DIR/rendered"
    if "$HELM" template "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" "${vargs[@]}" ${api[@]+"${api[@]}"} >"$OUTPUT_DIR/rendered/$rel.yaml" 2>"$log"; then
      ok "$(component_title "$comp"): rendered to output/rendered/$rel.yaml"
    else
      err "$(component_title "$comp"): rendering failed:"
      sed 's/^/         /' "$log" >&2
      return 1
    fi
    return 0
  fi

  info "Installing $(component_title "$comp") (release $rel). This can take up to $HELM_TIMEOUT..."
  if run_with_progress "$rel" "$log" "$HELM" upgrade --install "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" \
      "${vargs[@]}" --wait --timeout "$HELM_TIMEOUT"; then
    ok "$(component_title "$comp") is ready (log: output/logs/$rel.log)"
  else
    err "$(component_title "$comp") did not become ready."
    diagnose "$rel" "$log"
    exit 1
  fi
  if [[ "$comp" == s3 && "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then
    wait_obc_bound 600 || { diagnose_obc; exit 1; }
  fi
}

obc_name() { printf '%s-s3' "${EFFECTIVE_VALUES[global.namePrefix]}"; }

wait_obc_bound() {
  local timeout=$1 start=$SECONDS phase name
  name="$(obc_name)"
  info "Waiting for the Ceph RGW bucket (ObjectBucketClaim $name)..."
  while true; do
    phase="$(kcn get objectbucketclaim "$name" -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
    phase=${phase%$'\r'}
    if [[ "$phase" == Bound ]]; then ok "Bucket is ready (ObjectBucketClaim $name is Bound)"; return 0; fi
    if (( SECONDS - start >= timeout )); then err "ObjectBucketClaim $name is not Bound after $((timeout / 60)) minutes (phase: ${phase:-unknown})."; return 1; fi
    sleep 5
  done
}

diagnose_obc() {
  local name; name="$(obc_name)"
  info "Check the claim and the bucket StorageClass:"
  info "    kubectl -n $NAMESPACE describe objectbucketclaim $name"
  info "    kubectl get storageclass ${EFFECTIVE_VALUES[s3.rgw.storageClass]}"
  kcn describe objectbucketclaim "$name" 2>/dev/null | tail -n 15 | sed 's/^/    /' || true
}

# ----------------------------------------------------------------------------
# Checks against the live installation (upgrades)
# ----------------------------------------------------------------------------
declare -a RESIZE_PLAN=()   # "comp|statefulset|template|new size"
declare -A SAVED_EFFECTIVE_VALUES=()

save_effective_values()    { local k; SAVED_EFFECTIVE_VALUES=(); for k in "${!EFFECTIVE_VALUES[@]}"; do SAVED_EFFECTIVE_VALUES[$k]=${EFFECTIVE_VALUES[$k]}; done; }
restore_effective_values() { local k; EFFECTIVE_VALUES=(); for k in "${!SAVED_EFFECTIVE_VALUES[@]}"; do EFFECTIVE_VALUES[$k]=${SAVED_EFFECTIVE_VALUES[$k]}; done; }


# Warnings for changes of an existing installation, then the volume checks.
live_checks() {
  $CLUSTER_OK || return 0
  local -a comps=() others=()
  local c rel line p
  mapfile -t comps < <(selected_releases)
  RESIZE_PLAN=()

  # 1. Another name prefix already installed here?
  local mine=false
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^(.+)-(kafka|clickhouse|s3|otel)$ ]]; then
      p=${BASH_REMATCH[1]}
      if [[ "$p" == "${EFFECTIVE_VALUES[global.namePrefix]}" ]]; then mine=true
      elif [[ " ${others[*]} " != *" $p "* ]]; then others+=("$p"); fi
    fi
  done < <("$HELM" list -n "$NAMESPACE" -q 2>/dev/null || true)
  if ((${#others[@]} > 0)) && ! $mine; then
    heading "Existing installation"
    warn "Namespace $NAMESPACE already has releases with the name prefix: ${others[*]}"
    warn "global.namePrefix is '${EFFECTIVE_VALUES[global.namePrefix]}': this installs a SECOND, separate set (new volumes,"
    warn "new passwords) instead of updating it. To update it, set global.namePrefix: ${others[0]}"
    $DRY_RUN || confirm_or_exit "Install a second set with prefix '${EFFECTIVE_VALUES[global.namePrefix]}'?"
  fi

  # 2. Settings that change how CM MES connects.
  local -a changes=()
  save_effective_values
  local new_tls=${EFFECTIVE_VALUES[global.tls.mode]} new_s3=${EFFECTIVE_VALUES[s3.provider]}
  for c in "${comps[@]}"; do
    rel="$(release_name "$c")"
    release_exists "$rel" || continue
    make_tmp
    "$HELM" get values "$rel" -n "$NAMESPACE" -a -o yaml >"$TMP_DIR/live-$rel.yaml" 2>/dev/null || continue
    read_values --historical "$TMP_DIR/live-$rel.yaml"
    if [[ "$c" != otel && "${EFFECTIVE_VALUES[global.tls.mode]}" != "$new_tls" ]]; then
      changes+=("$(component_title "$c"): TLS mode ${EFFECTIVE_VALUES[global.tls.mode]} -> $new_tls. All its certificates change; CM MES must trust the new CA ($c-ca.crt).")
    fi
    if [[ "$c" == kafka && "${EFFECTIVE_VALUES[kafka.auth.method]:-}" == sasl ]]; then
      changes+=("Kafka: CM MES authentication changes from user name and password (SASL_SSL) to a client certificate (mTLS). CM MES can't connect until it uses the new values printed at the end.")
    fi
    if [[ "$c" == s3 && "${EFFECTIVE_VALUES[s3.provider]}" != "$new_s3" ]]; then
      changes+=("S3: provider ${EFFECTIVE_VALUES[s3.provider]} -> $new_s3. The data is NOT copied; CM MES starts with an empty bucket.")
    fi
    restore_effective_values
  done
  restore_effective_values
  if ((${#changes[@]} > 0)); then
    heading "Changes to the existing installation"
    for line in "${changes[@]}"; do warn "$line"; done
    $DRY_RUN || confirm_or_exit "Apply these changes?"
  fi

  # 3. Volumes (volumeClaimTemplates are immutable).
  for c in "${comps[@]}"; do
    [[ "$c" == otel ]] || check_volumes "$c"
  done
  if ((${#RESIZE_PLAN[@]} > 0)); then
    [[ "$ACTION" == resize ]] || $DRY_RUN || die "Volume growth requires explicit maintenance: rerun with --resize-storage and the same values file. No volumes or controllers were changed."
    local comp sts vct size lsize
    heading "Volume resize"
    info "These volumes will be enlarged. Kubernetes cannot change the volume size of a StatefulSet,"
    info "so install.sh resizes each existing volume, then deletes the StatefulSet object only"
    info "(--cascade=orphan: the pods keep running) and the upgrade recreates it with the new size."
    info "Some storage drivers finish growing the file system only when the pod restarts."
    for line in "${RESIZE_PLAN[@]}"; do
      IFS='|' read -r comp sts vct size lsize <<<"$line"
      info "  - $sts, volumes '$vct': $lsize -> $size"
    done
    if $DRY_RUN; then note "Dry run: nothing is resized."; return 0; fi
    require_can_i patch persistentvolumeclaims
    require_can_i delete statefulsets.apps
  fi
}

# Installation uses Helm; storage changes require the explicit maintenance action.

run_install() {
  local -a comps=()
  mapfile -t comps < <(selected_releases)

  heading "Preparing"
  local c
  prepare_charts
  if [[ "${EFFECTIVE_VALUES[global.tls.mode]}" == auto ]]; then
    if $DRY_RUN; then note "Dry run: the CA Secret is not created (each chart would render its own CA)."
    else ensure_ca; fi
  fi

  heading "$($DRY_RUN && echo Rendering || echo Installing)"
  local failed=0
  for c in "${comps[@]}"; do
    install_release "$c" || failed=1
  done
  if $DRY_RUN; then
    ((failed == 0)) || die "Some charts could not be rendered (see above)."
    info ""
    info "Nothing was installed. Review the files in $OUT_SHOW/rendered/ and run again without --dry-run."
    return 0
  fi
  print_connection_info true
  final_message "${comps[@]}"
}

# ----------------------------------------------------------------------------
# Connection information
# ----------------------------------------------------------------------------

rgw_block() {   # prints the S3 block for a Ceph RGW bucket (from the OBC ConfigMap/Secret)
  local name host bucket port key secret scheme addr
  name="$(obc_name)"
  host="$(kcn get configmap "$name" -o 'jsonpath={.data.BUCKET_HOST}' 2>/dev/null || true)"
  bucket="$(kcn get configmap "$name" -o 'jsonpath={.data.BUCKET_NAME}' 2>/dev/null || true)"
  port="$(kcn get configmap "$name" -o 'jsonpath={.data.BUCKET_PORT}' 2>/dev/null || true)"
  host=${host%$'\r'}; bucket=${bucket%$'\r'}; port=${port%$'\r'}
  if [[ -z "$host" || -z "$bucket" ]]; then
    warn "The ObjectBucketClaim $name has no ConfigMap yet (is it Bound?)."; return 1
  fi
  key="$(kcn get secret "$name" -o 'jsonpath={.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | tr -d '\r' | b64d || true)"
  secret="$(kcn get secret "$name" -o 'jsonpath={.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | tr -d '\r' | b64d || true)"
  [[ -n "$port" ]] || port=80
  # Same layout as the RustFS block: host only on 443 (HTTPS), host:port otherwise.
  if [[ "$port" == 443 ]]; then scheme=https; addr=$host; else scheme=http; addr="$host:$port"; fi
  printf '[S3]\n'
  printf '%-42s: %s\n' "Address" "$addr" "Bucket Name" "$bucket" "AccessKey Id" "$key" \
    "Secret Access Key" "$secret" "Use Path Style" "true"
  if [[ "$scheme" == https ]]; then
    local ca
    ca="$(kcn get configmap openshift-service-ca.crt -o 'jsonpath={.data.service-ca\.crt}' 2>/dev/null || true)"
    if [[ -n "$ca" ]]; then
      printf '%s\n' "$ca" | tr -d '\r' >"$OUTPUT_DIR/s3-ca.crt"
      printf '%-42s: %s\n' "Certificate Authority" "s3-ca.crt"
    fi
  fi
  printf '%-42s: %s\n' "(info) Endpoint URL" "$scheme://$host:$port"
}

print_connection_info() {
  local after_install=${1:-false}
  local prefix=${EFFECTIVE_VALUES[global.namePrefix]} out entries=() line name order comp ca files fsecret
  local -a sorted=()
  SAVED_FILES=()
  mkdir -p "$OUTPUT_DIR"
  chmod 700 "$OUTPUT_DIR" 2>/dev/null || true
  umask 077

  out="$(kcn get secret -l "$CONNECTION_LABEL" -o "jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.metadata.annotations.${ANN}/order}{\"|\"}{.metadata.annotations.${ANN}/component}{\"|\"}{.metadata.annotations.${ANN}/ca-secret}{\"|\"}{.metadata.annotations.${ANN}/files}{\"|\"}{.metadata.annotations.${ANN}/files-secret}{\"\\n\"}{end}" 2>/dev/null)" \
    || die "Cannot read the connection Secrets in namespace $NAMESPACE."
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -n "$line" && "$line" == "$prefix-"* ]] || continue
    order=$(cut -d'|' -f2 <<<"$line"); [[ "$order" =~ ^[0-9]+$ ]] || order=50
    comp=$(cut -d'|' -f3 <<<"$line")
    # Ceph RGW: the S3 values come from the ObjectBucketClaim (rgw_block), not from a Secret.
    [[ "$comp" == s3 && "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]] && continue
    entries+=("$order|secret|$line")
  done <<<"$out"
  if enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then entries+=("30|rgw|"); fi
  if ((${#entries[@]} == 0)); then
    warn "No connection information found in namespace $NAMESPACE for prefix '$prefix'."
    info "Is it installed? Check with: $HELM list -n $NAMESPACE"
    return 1
  fi
  mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1n)

  heading "Values for the CM MES installer"
  local info_file="$OUTPUT_DIR/connection-info.txt" block kind rest
  {
    printf '# CM MES v12 external dependencies - namespace %s - %s\n' "$NAMESPACE" "$(date '+%Y-%m-%d %H:%M')"
    printf '# Contains passwords: keep this file private.\n'
  } >"$info_file"
  for line in "${sorted[@]}"; do
    kind=$(cut -d'|' -f2 <<<"$line")
    rest=${line#*|*|}
    if [[ "$kind" == rgw ]]; then
      if ! block="$(rgw_block)"; then continue; fi
      [[ "$block" == *s3-ca.crt* ]] && SAVED_FILES+=("s3-ca.crt")
    else
      IFS='|' read -r name order comp ca files fsecret <<<"$rest"
      comp=${comp:-${name#"$prefix"-}}; comp=${comp%-connection}
      block="$(kcn get secret "$name" -o 'jsonpath={.data.mes-installer\.txt}' 2>/dev/null | tr -d '\r' | b64d || true)"
      [[ -n "$block" ]] || { warn "Secret $name has no mes-installer.txt."; continue; }
      [[ -n "$ca" ]] && save_secret_key "$ca" ca.crt "$(safe_name "$comp")-ca.crt"
      if [[ -n "$files" && -n "$fsecret" ]]; then
        local f
        IFS=, read -r -a _files <<<"$files"
        for f in "${_files[@]}"; do
          f="$(trim "$f")"; [[ -n "$f" ]] || continue
          save_secret_key "$fsecret" "$f" "$(safe_name "$comp")-$(safe_name "$f")"
        done
      fi
    fi
    printf '\n%s\n' "$block"
    printf '\n%s\n' "$block" >>"$info_file"
  done
  info ""
  ok "Saved to $OUT_SHOW/connection-info.txt"
  local f
  for f in ${SAVED_FILES[@]+"${SAVED_FILES[@]}"}; do ok "Saved $OUT_SHOW/$f"; done
  if ! $after_install; then
    note "Upload the .crt/.key files in the CM MES installer where the values above name them."
  fi
}

final_message() {
  local p=${EFFECTIVE_VALUES[global.namePrefix]} c
  heading "Done"
  info "The dependencies are installed in namespace '$NAMESPACE'."
  info ""
  info "Next steps:"
  info "  1. Open the CM MES installer and type the values shown above (also in"
  info "     $OUT_SHOW/connection-info.txt)."
  info "  2. Where a certificate file is named (e.g. kafka-ca.crt), upload that file from $OUT_SHOW/."
  info "     The CM MES installer also lets you add custom CAs or skip the certificate validation."
  if [[ " $* " == *" clickhouse "* ]]; then
    info "     For ClickHouse, also fill 'Cluster Name': without it CM MES creates each table on only"
    info "     one ClickHouse server, and it isn't highly available."
  fi
  info "  3. Optional: prove that each component accepts the MES credentials:"
  for c in "$@"; do [[ "$c" == otel ]] || info "       $HELM test $p-$c -n $NAMESPACE"; done
  info ""
  warn "The files in $OUT_SHOW contain passwords and keys: keep them private and delete them"
  warn "when the CM MES installation is done. Show them again any time with: ./install.sh -n $NAMESPACE --print"
  if ! otel_enabled; then
    info ""
    warn "No monitoring is installed. We recommend CM Observability: $CM_OBSERVABILITY_URL"
  fi
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
run_uninstall() {
  local p=${EFFECTIVE_VALUES[global.namePrefix]} c rel context
  local -a present=()
  for c in otel s3 clickhouse kafka; do
    rel="$p-$c"
    "$HELM" status "$rel" -n "$NAMESPACE" >/dev/null 2>&1 && present+=("$rel")
  done
  if ((${#present[@]} == 0)); then
    info "No release with prefix '$p' is installed in namespace $NAMESPACE (see: $HELM list -n $NAMESPACE)."
    return 0
  fi
  heading "Uninstall"
  info "These releases will be removed from namespace $NAMESPACE: ${present[*]}"
  info "The data volumes (PersistentVolumeClaims) and the CA Secrets are KEPT, so a new"
  info "installation with the same prefix reuses the existing data."
  enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]] && \
    info "The Ceph RGW bucket (ObjectBucketClaim $p-s3) is kept as well."
  context="$(kc config current-context 2>/dev/null || true)"
  context=${context%$'\r'}
  confirm_or_exit "Uninstall ${present[*]} from namespace $NAMESPACE (context ${context:-?})? The data volumes are kept"
  for rel in "${present[@]}"; do
    if "$HELM" uninstall "$rel" -n "$NAMESPACE" >/dev/null 2>&1; then ok "Uninstalled $rel"; else err "Could not uninstall $rel ($HELM uninstall $rel -n $NAMESPACE)"; fi
  done

  local pvcs secrets
  pvcs="$(kcn get pvc -o name 2>/dev/null | tr -d '\r' | grep -E "(/|-)$p-(kafka|clickhouse|keeper|s3)" || true)"
  secrets="$(kcn get secret -o name 2>/dev/null | tr -d '\r' | grep -E "^secret/$p-" || true)"
  heading "Kept data"
  if [[ -n "$pvcs" ]]; then
    info "Data volumes still present (they hold all Kafka, ClickHouse and S3 data):"
    printf '%s\n' "$pvcs" | sed 's/^/    /'
    info ""
    warn "To delete the data PERMANENTLY (cannot be undone):"
    info "    kubectl -n $NAMESPACE delete $(printf '%s\n' "$pvcs" | tr '\n' ' ')"
  else
    info "No data volumes with prefix '$p' are left."
  fi
  if [[ -n "$secrets" ]]; then
    info ""
    info "Secrets still present (e.g. the CA certificates, kept so that a reinstall trusts the same CA):"
    printf '%s\n' "$secrets" | sed 's/^/    /'
    info "To delete them: kubectl -n $NAMESPACE delete $(printf '%s\n' "$secrets" | tr '\n' ' ')"
  fi
  if enabled s3 && [[ "${EFFECTIVE_VALUES[s3.provider]}" == rgw ]]; then
    info ""
    warn "To delete the Ceph RGW bucket and ALL its data (cannot be undone):"
    info "    kubectl -n $NAMESPACE delete objectbucketclaim $p-s3"
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  parse_args "$@"
  umask 077   # everything written (answers, connection info, keys) is private
  [[ -f "$BASE_VALUES_FILE" ]] || die "$BASE_VALUES_FILE not found. Run install.sh from the installer folder."
  [[ "$ACTION" == install && -z "$USER_VALUES" ]] && INTERACTIVE=true

  printf '%sCritical Manufacturing MES v12 - external dependencies installer%s\n' "$C_BOLD" "$C_RESET"
  case "$ACTION" in
    print|uninstall)
      heading "Checking prerequisites"
      check_tools "$MIN_HELM_MAJOR" "$MIN_HELM_MINOR"
      check_cluster true ""
      choose_namespace
      set_values_files
      read_values "${VALUES_FILES[@]}"
      if [[ "$ACTION" == print ]]; then print_connection_info false; else run_uninstall; fi
      return 0 ;;
  esac

  if $INTERACTIVE && [[ -f "$GENERATED_VALUES" ]]; then
    heading "Previous answers found"
    info "$GENERATED_VALUES exists (written by an earlier run of this wizard)."
    local reuse
    ask_yn reuse "Use it as it is, without questions (same as: -f $GENERATED_VALUES)?" y
    if $reuse; then
      INTERACTIVE=false; USER_VALUES=$GENERATED_VALUES
      # The wizard records the namespace in the header of the file.
      [[ -n "$NAMESPACE" ]] || NAMESPACE="$(sed -En 's/^# Generated by install.sh .* for namespace "([^"]*)"\.$/\1/p' "$GENERATED_VALUES" | tr -d '\r' | head -n 1)"
    else note "The wizard starts with those answers as defaults."; fi
  fi

  if $INTERACTIVE; then
    heading "Step 1/8 - Prerequisites"
    note "Answer each question, or press Enter to accept the value in [brackets]."
  else
    heading "Checking prerequisites"
  fi
  check_tools "$MIN_HELM_MAJOR" "$MIN_HELM_MINOR"
  if $DRY_RUN && ! $INTERACTIVE; then check_cluster false ""; else check_cluster true "Install into this cluster?"; fi
  choose_namespace
  check_namespace

  if $INTERACTIVE; then heading "Step 2/8 - Looking at the cluster"; else heading "Looking at the cluster"; fi
  if $CLUSTER_OK; then detect_cluster; else note "Skipped (no cluster)."; fi

  if $INTERACTIVE; then
    # BASE_VALUES = values.yaml alone: the wizard writes only what differs from it.
    read_values "$BASE_VALUES_FILE"
    local k; BASE_VALUES=(); for k in "${!EFFECTIVE_VALUES[@]}"; do BASE_VALUES[$k]=${EFFECTIVE_VALUES[$k]}; done
  fi
  set_values_files
  read_values "${VALUES_FILES[@]}"

  if $INTERACTIVE; then
    run_wizard
    heading "Step 8/8 - Confirm"
    # Show the result of the answers: write them to a temporary file and read the merge back.
    make_tmp
    local tmpv="$TMP_DIR/answers.yaml"
    ( umask 077; emit_overrides >"$tmpv" )
    VALUES_FILES=("$BASE_VALUES_FILE" "$tmpv")
    VALUES_DISPLAY="values.yaml + your answers (saved as $GENERATED_VALUES)"
    read_values "${VALUES_FILES[@]}"
    show_summary
    preflight_checks
    prepare_charts
    live_checks
    confirm_or_exit "$($DRY_RUN && echo "Save the answers and render the manifests?" || echo "Save the answers and install now?")"
    write_generated "$GENERATED_VALUES"
    note "Re-running './install.sh -n $NAMESPACE -f $GENERATED_VALUES' reproduces this installation."
    VALUES_FILES=("$BASE_VALUES_FILE" "$GENERATED_VALUES")
    VALUES_DISPLAY=""
  else
    show_summary
    preflight_checks
    prepare_charts
    live_checks
    # A dry run changes nothing, so it needs no confirmation.
    if [[ "$ACTION" == install ]]; then $DRY_RUN || confirm_or_exit "Install now?"; fi
  fi
  if [[ "$ACTION" == resize ]]; then run_storage_maintenance; else run_install; fi
}

main "$@"
