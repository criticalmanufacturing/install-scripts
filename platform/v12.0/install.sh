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

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${SCRIPT_DIR}/charts"
BASE_VALUES="${SCRIPT_DIR}/values.yaml"
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
ASSUME_YES=false
DRY_RUN=false
HELM_TIMEOUT="20m"
INTERACTIVE=false

CLUSTER_OK=false
IS_OPENSHIFT=false
HAS_CERT_MANAGER=false
HAS_OBC=false
NODE_COUNT="unknown"
DEFAULT_SC=""
KUBE_CONTEXT=""
CHARTS_READY=false
declare -a STORAGE_CLASSES=()   # "name|provisioner|default(true/empty)"
declare -a RGW_CLASSES=()       # bucket StorageClass names (Ceph RGW)
declare -A V=()                 # effective values (read through helm)
declare -A OV=()                # wizard overrides: path -> YAML value
declare -A W=()                 # wizard answers: path -> plain value
declare -A B=()                 # values.yaml alone (the wizard writes only differences from it)
declare -a VALUES_FILES=()      # values files passed to every release
declare -a SAVED_FILES=()       # files written to ./output by print_connection_info
VALUES_DISPLAY=""
TMP_DIR=""

# ----------------------------------------------------------------------------
# Output helpers (colours only on a terminal)
# ----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_DIM=""; C_RESET=""
fi

heading() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }
info()    { if [[ -z "$*" ]]; then printf '\n'; else printf '  %s\n' "$*"; fi; }
note()    { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()      { printf '  %s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()     { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }

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
# Prompt helpers (read from stdin, so answers can also be piped in)
# ----------------------------------------------------------------------------
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# read_line <var>: one line from stdin, trimmed, CR removed.
read_line() {
  local __line=""
  if ! IFS= read -r __line; then
    [[ -n "$__line" ]] || { printf '\n'; die "No more answers on standard input. Run ./install.sh in a terminal, or use: -f <values file> --yes"; }
  fi
  __line="$(trim "${__line%$'\r'}")"
  [[ -t 0 ]] || printf '%s\n' "$__line"
  printf -v "$1" '%s' "$__line"
}

# ask <var> <question> [default]
ask() {
  local __var=$1 __q=$2 __def=${3-} __ans
  if [[ -n "$__def" ]]; then
    printf '  %s%s%s [%s]: ' "$C_BOLD" "$__q" "$C_RESET" "$__def"
  else
    printf '  %s%s%s: ' "$C_BOLD" "$__q" "$C_RESET"
  fi
  read_line __ans
  [[ -n "$__ans" ]] || __ans=$__def
  printf -v "$__var" '%s' "$__ans"
}

# ask_secret <var> <question>: hidden input on a terminal.
ask_secret() {
  local __var=$1 __q=$2 __ans=""
  printf '  %s%s%s: ' "$C_BOLD" "$__q" "$C_RESET"
  if [[ -t 0 ]]; then
    IFS= read -rs __ans || true
    printf '\n'
  else
    IFS= read -r __ans || [[ -n "$__ans" ]] || die "No more answers on standard input."
    printf '(hidden)\n'
  fi
  printf -v "$__var" '%s' "${__ans%$'\r'}"
}

# ask_yn <var> <question> <default y|n>  -> var = true | false
ask_yn() {
  local __var=$1 __q=$2 __def=$3 __ans __hint
  if [[ "$__def" == y ]]; then __hint="Y/n"; else __hint="y/N"; fi
  while true; do
    printf '  %s%s%s [%s]: ' "$C_BOLD" "$__q" "$C_RESET" "$__hint"
    read_line __ans
    [[ -n "$__ans" ]] || __ans=$__def
    case "${__ans,,}" in
      y|yes) printf -v "$__var" true; return 0 ;;
      n|no)  printf -v "$__var" false; return 0 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

# ask_choice <var> <question> <default value> "value|description" ...
ask_choice() {
  local __var=$1 __q=$2 __def=$3; shift 3
  local -a __vals=() __descs=()
  local __o __i __ans __defidx=1 __w=14
  for __o in "$@"; do
    __vals+=("${__o%%|*}"); __descs+=("${__o#*|}")
    (( ${#__vals[-1]} > __w )) && __w=${#__vals[-1]}
  done
  printf '  %s%s%s\n' "$C_BOLD" "$__q" "$C_RESET"
  for __i in "${!__vals[@]}"; do
    printf '    %2d) %-*s %s\n' $((__i + 1)) "$__w" "${__vals[__i]}" "${__descs[__i]}"
    [[ "${__vals[__i]}" == "$__def" ]] && __defidx=$((__i + 1))
  done
  while true; do
    printf '  Choice [%d]: ' "$__defidx"
    read_line __ans
    [[ -n "$__ans" ]] || __ans=$__defidx
    if [[ "$__ans" =~ ^[0-9]+$ ]] && (( __ans >= 1 && __ans <= ${#__vals[@]} )); then
      printf -v "$__var" '%s' "${__vals[__ans - 1]}"; return 0
    fi
    for __i in "${!__vals[@]}"; do
      if [[ "${__vals[__i]}" == "$__ans" ]]; then printf -v "$__var" '%s' "$__ans"; return 0; fi
    done
    warn "Please type a number between 1 and ${#__vals[@]}."
  done
}

confirm_or_exit() {
  local q=$1 answer
  if $ASSUME_YES; then return 0; fi
  if [[ ! -t 0 ]] && ! $INTERACTIVE; then
    die "Confirmation needed but standard input is not a terminal. Add --yes to proceed."
  fi
  ask_yn answer "$q" y
  $answer || { info "Cancelled. Nothing was changed."; exit 0; }
}

# ----------------------------------------------------------------------------
# Small utilities
# ----------------------------------------------------------------------------
kc()  { "$KUBECTL" "$@"; }
kcn() { "$KUBECTL" -n "$NAMESPACE" "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

# base64 decode from stdin (GNU, BSD/macOS and Git Bash all accept --decode).
b64d() { base64 --decode 2>/dev/null; }

# Quote a string for YAML (double-quoted style).
yaml_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}

is_dns_label()  { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 63 ]]; }
is_secret_name(){ [[ "$1" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && ${#1} -le 253 ]]; }
is_size()       { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?(Mi|Gi|Ti)$ ]]; }

# Absolute path of an existing file (for comparing values files).
abs_path() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

release_name() { printf '%s-%s' "${V[global.namePrefix]}" "$1"; }

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
  clickhouse.keeper.replicas clickhouse.keeper.storage.size
  s3.enabled s3.provider s3.bucket s3.rustfs.replicas s3.rustfs.volumesPerPod
  s3.rustfs.tls.existingSecret s3.rustfs.storage.size s3.rgw.storageClass
  kafka.storage.storageClass clickhouse.storage.storageClass clickhouse.keeper.storage.storageClass
  s3.rustfs.storage.storageClass s3.rustfs.allowSharedDisks
  observability.otlpEndpoint observability.headers observability.tls.insecureSkipVerify
  observability.tls.ca observability.headers@json observability.tls.ca@json
)

make_tmp() { [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t cmmes)"; }

build_reader_chart() {
  make_tmp
  local dir="$TMP_DIR/values-reader" k
  [[ -f "$dir/Chart.yaml" ]] && return 0
  mkdir -p "$dir/templates"
  printf 'apiVersion: v2\nname: values-reader\nversion: 0.0.0\n' >"$dir/Chart.yaml"
  { printf '__cmReaderKeys:\n'; for k in "${VALUE_KEYS[@]}"; do printf '  - "%s"\n' "$k"; done; } >"$dir/values.yaml"
  # Prints "K|<path>|<value>" for every key. Maps -> sorted key names, lists -> comma-separated.
  cat >"$dir/templates/values.yaml" <<'EOF'
{{- define "v" -}}
{{- if kindIs "map" . -}}{{- keys . | sortAlpha | join "," -}}
{{- else if kindIs "slice" . -}}
{{- $l := list -}}
{{- range . -}}{{- if kindIs "map" . -}}{{- $l = append $l (toString (.name | default "")) -}}{{- else -}}{{- $l = append $l (toString .) -}}{{- end -}}{{- end -}}
{{- join "," $l -}}
{{- else if kindIs "invalid" . -}}
{{- else -}}{{- toString . | replace "\r" "" | replace "\n" "\\n" -}}
{{- end -}}
{{- end -}}
{{- range $p := .Values.__cmReaderKeys }}
{{- $cur := $.Values -}}{{- $found := true -}}
{{- $json := hasSuffix "@json" $p -}}
{{- range $k := splitList "." (trimSuffix "@json" $p) -}}
{{- if and $found (kindIs "map" $cur) (hasKey $cur $k) -}}{{- $cur = index $cur $k -}}{{- else -}}{{- $found = false -}}{{- end -}}
{{- end }}
# K|{{ $p }}|{{ if and $found $json }}{{ toJson $cur }}{{ else if $found }}{{ include "v" $cur }}{{ end }}
{{- end }}
EOF
}

# read_values <file>...: fills V[] with the merged values of the given files.
read_values() {
  build_reader_chart
  local -a args=()
  local f out line key value
  for f in "$@"; do args+=(-f "$f"); done
  if ! out="$("$HELM" template values-reader "$TMP_DIR/values-reader" "${args[@]}" 2>&1)"; then
    err "Could not read the values file(s): $*"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
    die "Fix the YAML syntax (indentation with spaces, 'key: value') and try again."
  fi
  V=()
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ "$line" == "# K|"* ]] || continue
    line=${line#"# K|"}
    key=${line%%|*}
    value=${line#*|}
    V["$key"]=$value
  done <<<"$out"
  # Defaults for keys that are missing from every file.
  : "${V[global.namePrefix]:=cmmes}"
  [[ -n "${V[global.namePrefix]}" ]] || V[global.namePrefix]=cmmes
  : "${V[global.tls.mode]:=auto}"; [[ -n "${V[global.tls.mode]}" ]] || V[global.tls.mode]=auto
  : "${V[global.podAntiAffinity]:=hard}"
  : "${V[global.platform]:=auto}"
  : "${V[kafka.auth.method]:=sasl}"; [[ -n "${V[kafka.auth.method]}" ]] || V[kafka.auth.method]=sasl
  : "${V[s3.provider]:=rustfs}"; [[ -n "${V[s3.provider]}" ]] || V[s3.provider]=rustfs
  local c
  for c in "${COMPONENTS[@]}"; do
    [[ -n "${V[$c.enabled]:-}" ]] || V[$c.enabled]=true
  done
}

enabled() { [[ "${V[$1.enabled]:-true}" == "true" ]]; }
otel_enabled() { [[ -n "${V[observability.otlpEndpoint]:-}" ]]; }

validate_values() {
  local p=${V[global.namePrefix]}
  is_dns_label "$p" && [[ ${#p} -le 20 ]] || die "global.namePrefix '$p' is invalid: use at most 20 lowercase letters, digits and '-'."
  case "${V[global.tls.mode]}" in auto|existing|certManager) ;; *)
    die "global.tls.mode must be auto, existing or certManager (got '${V[global.tls.mode]}')." ;; esac
  case "${V[kafka.auth.method]}" in sasl|mtls) ;; *)
    die "kafka.auth.method must be sasl or mtls (got '${V[kafka.auth.method]}')." ;; esac
  case "${V[s3.provider]}" in rustfs|rgw) ;; *)
    die "s3.provider must be rustfs or rgw (got '${V[s3.provider]}')." ;; esac
  case "${V[global.podAntiAffinity]}" in hard|soft) ;; *)
    die "global.podAntiAffinity must be hard or soft (got '${V[global.podAntiAffinity]}')." ;; esac
  case "${V[global.platform]}" in auto|openshift|kubernetes) ;; *)
    die "global.platform must be auto, openshift or kubernetes (got '${V[global.platform]}')." ;; esac
  local c
  for c in "${COMPONENTS[@]}"; do
    case "${V[$c.enabled]}" in true|false) ;; *) die "$c.enabled must be true or false (got '${V[$c.enabled]}')." ;; esac
  done
  if ! enabled kafka && ! enabled clickhouse && ! enabled s3; then
    die "No component is enabled (kafka.enabled, clickhouse.enabled and s3.enabled are all false)."
  fi
  if [[ "${V[global.tls.mode]}" == certManager && -z "${V[global.tls.certManager.issuerName]:-}" ]]; then
    die "global.tls.mode=certManager needs global.tls.certManager.issuerName."
  fi
  if [[ "${V[global.tls.mode]}" == existing ]]; then
    local missing=()
    enabled kafka && [[ -z "${V[kafka.tls.existingSecret]:-}" ]] && missing+=(kafka.tls.existingSecret)
    enabled kafka && [[ "${V[kafka.auth.method]}" == mtls && -z "${V[kafka.tls.existingClientSecret]:-}" ]] && missing+=(kafka.tls.existingClientSecret)
    enabled clickhouse && [[ -z "${V[clickhouse.tls.existingSecret]:-}" ]] && missing+=(clickhouse.tls.existingSecret)
    enabled s3 && [[ "${V[s3.provider]}" == rustfs && -z "${V[s3.rustfs.tls.existingSecret]:-}" ]] && missing+=(s3.rustfs.tls.existingSecret)
    ((${#missing[@]} == 0)) || die "global.tls.mode=existing needs these Secret names: ${missing[*]}"
  fi
  local ep=${V[observability.otlpEndpoint]:-}
  if [[ -n "$ep" && ! "$ep" =~ ^https?:// ]]; then
    die "observability.otlpEndpoint must start with http:// or https:// (got '$ep')."
  fi
}

# ----------------------------------------------------------------------------
# Step 1: prerequisites
# ----------------------------------------------------------------------------
check_tools() {
  local missing_tool=0 t
  if have "$KUBECTL"; then ok "$KUBECTL found: $(command -v "$KUBECTL")"; else
    err "'$KUBECTL' was not found in PATH."
    info "Install kubectl: https://kubernetes.io/docs/tasks/tools/ (or set KUBECTL=oc on OpenShift)"
    missing_tool=1
  fi
  if have "$HELM"; then ok "$HELM found: $(command -v "$HELM")"; else
    err "'$HELM' was not found in PATH."
    info "Install helm: https://helm.sh/docs/intro/install/"
    missing_tool=1
  fi
  [[ "$missing_tool" == 0 ]] || exit 1
  for t in sed awk grep sort base64; do have "$t" || die "'$t' was not found in PATH."; done
  if have openssl; then ok "openssl found"; else warn "openssl was not found: it is needed to create the CA in TLS mode 'auto'."; fi

  local ver major minor rest
  ver="$("$HELM" version --template '{{.Version}}' 2>/dev/null || true)"
  ver=${ver#v}
  major=${ver%%.*}; rest=${ver#*.}; minor=${rest%%.*}
  major=${major//[!0-9]/}; minor=${minor//[!0-9]/}
  if [[ -z "$major" || -z "$minor" ]]; then
    die "Could not determine the helm version ('$HELM version' failed). Helm ${MIN_HELM_MAJOR}.${MIN_HELM_MINOR} or newer is required."
  fi
  if (( major < MIN_HELM_MAJOR || (major == MIN_HELM_MAJOR && minor < MIN_HELM_MINOR) )); then
    die "Helm v$ver is too old. Install Helm ${MIN_HELM_MAJOR}.${MIN_HELM_MINOR} or newer: https://helm.sh/docs/intro/install/"
  fi
  ok "helm v$ver"
}

check_cluster() {
  local strict=$1       # true = fail when the cluster is unreachable
  local question=${2-}  # yes/no question to confirm the context ("" = do not ask)
  local ctx server out
  ctx="$(kc config current-context 2>/dev/null || true)"
  if [[ -z "$ctx" ]]; then
    if $strict; then die "kubectl has no current context. Log in to the cluster first (e.g. 'oc login ...' or set KUBECONFIG)."; fi
    warn "kubectl has no current context: continuing without cluster checks (dry run)."; return 0
  fi
  server="$(kc config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
  # MSYS_NO_PATHCONV: stops Git Bash from turning "/version" into a Windows path.
  if ! out="$(MSYS_NO_PATHCONV=1 kc get --raw /version --request-timeout=20s 2>&1)"; then
    if $strict; then
      err "Cannot reach the cluster of context '$ctx' (${server:-unknown server}):"
      printf '%s\n' "$out" | head -n 3 | sed 's/^/         /' >&2
      die "Check your network/VPN and that you are logged in (kubectl get pods should work)."
    fi
    warn "Cannot reach the cluster: continuing without cluster checks (dry run)."; return 0
  fi
  CLUSTER_OK=true
  KUBE_CONTEXT=$ctx
  ok "Cluster reachable. Context: ${C_BOLD}$ctx${C_RESET} (${server:-unknown server})"
  if [[ -n "$question" ]] && ! $ASSUME_YES && [[ -t 0 || "$INTERACTIVE" == true ]]; then
    local yes
    ask_yn yes "$question" y
    $yes || die "Switch the context first: kubectl config use-context <name>"
  fi
}

choose_namespace() {
  local def
  if [[ -z "$NAMESPACE" ]]; then
    def="$(kc config view --minify -o 'jsonpath={..namespace}' 2>/dev/null || true)"
    [[ -n "$def" ]] || def=default
    if $INTERACTIVE; then
      note "The namespace must already exist (this installer does not create it)."
      while true; do
        ask NAMESPACE "Namespace to install into" "$def"
        is_dns_label "$NAMESPACE" && break
        warn "'$NAMESPACE' is not a valid namespace name."
      done
    else
      NAMESPACE=$def
      info "No -n given: using the namespace of the current context: $NAMESPACE"
    fi
  fi
  is_dns_label "$NAMESPACE" || die "'$NAMESPACE' is not a valid namespace name."
}

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
require_can_i() {
  local verb=$1 r ans
  local -a denied=()
  shift
  for r in "$@"; do
    ans="$(kcn auth can-i "$verb" "$r" 2>/dev/null || true)"
    ans=${ans%$'\r'}
    [[ "$ans" == yes ]] || denied+=("$r")
  done
  if ((${#denied[@]} > 0)); then
    die "You cannot $verb ${denied[*]} in namespace '$NAMESPACE'. Ask for the 'admin' role on this namespace (kubectl create rolebinding ... --clusterrole=admin)."
  fi
}

# ----------------------------------------------------------------------------
# Step 2: detection
# ----------------------------------------------------------------------------
api_group_has() {   # api_group_has <group> <resource>
  kc api-resources --api-group="$1" -o name 2>/dev/null | tr -d '\r' | grep -Eq "^$2(\.|$)"
}

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
  STORAGE_CLASSES=(); RGW_CLASSES=(); DEFAULT_SC=""
  if out="$(kc get storageclass -o "jsonpath={range .items[*]}{.metadata.name}{\"|\"}{.provisioner}{\"|\"}{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}{\"\\n\"}{end}" 2>/dev/null)"; then
    while IFS='|' read -r name prov def; do
      name=${name%$'\r'}; def=${def%$'\r'}
      [[ -n "$name" ]] || continue
      if [[ "$prov" == *ceph.rook.io/bucket && "$prov" != *noobaa* && "$name" != *noobaa* ]]; then
        RGW_CLASSES+=("$name"); continue
      fi
      [[ "$prov" == *noobaa* || "$prov" == *bucket* ]] && continue
      STORAGE_CLASSES+=("$name|$prov|$def")
      [[ "$def" == true ]] && DEFAULT_SC=$name
    done <<<"$out"
    if ((${#STORAGE_CLASSES[@]} == 0)); then
      warn "No StorageClass found: the data volumes cannot be created. Ask your cluster administrator."
    else
      ok "StorageClasses: $(for s in "${STORAGE_CLASSES[@]}"; do printf '%s ' "${s%%|*}"; done)${DEFAULT_SC:+(default: $DEFAULT_SC)}"
      [[ -n "$DEFAULT_SC" ]] || warn "No default StorageClass: you will have to choose one."
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
# set_ov <path> <yaml value> <plain value>: remember an override if it differs from values.yaml.
set_ov() {
  local base=${B[$1]:-}
  [[ -z "$base" && "$3" == false ]] && base=false   # unset boolean = false
  if [[ "$base" != "$3" ]]; then OV["$1"]=$2; else unset 'OV[$1]'; fi
}

OV_ORDER=(
  global.namePrefix global.storageClass global.imageRegistry global.imagePullSecrets
  global.podAntiAffinity global.tls.mode global.tls.certManager.issuerName
  global.tls.certManager.issuerKind
  kafka.enabled kafka.auth.method kafka.tls.existingSecret kafka.tls.existingClientSecret kafka.storage.size
  clickhouse.enabled clickhouse.tls.existingSecret clickhouse.storage.size clickhouse.keeper.storage.size
  s3.enabled s3.provider s3.rustfs.tls.existingSecret s3.rustfs.storage.size s3.rustfs.storage.storageClass
  s3.rustfs.allowSharedDisks s3.rgw.storageClass
  observability.otlpEndpoint observability.headers observability.tls.insecureSkipVerify observability.tls.ca
)

# Writes OV[] as nested YAML (keys in OV_ORDER, which keeps siblings together).
emit_overrides() {
  local -a prev=() parts=()
  local path val i j depth ind first=true
  for path in "${OV_ORDER[@]}"; do
    [[ -n "${OV[$path]+x}" ]] || continue
    val=${OV[$path]}
    IFS=. read -r -a parts <<<"$path"
    i=0
    while (( i < ${#parts[@]} - 1 && i < ${#prev[@]} - 1 )) && [[ "${parts[i]}" == "${prev[i]}" ]]; do i=$((i + 1)); done
    if (( i == 0 )) && ! $first; then printf '\n'; fi
    first=false
    for ((j = i; j < ${#parts[@]} - 1; j++)); do printf '%*s%s:\n' $((j * 2)) '' "${parts[j]}"; done
    depth=$(( (${#parts[@]} - 1) * 2 ))
    if [[ "$val" == "|"$'\n'* ]]; then          # block scalar (multi-line text)
      printf '%*s%s: |\n' "$depth" '' "${parts[${#parts[@]} - 1]}"
      ind=$((depth + 2))
      while IFS= read -r j; do printf '%*s%s\n' "$ind" '' "$j"; done <<<"${val#|$'\n'}"
    else
      printf '%*s%s: %s\n' "$depth" '' "${parts[${#parts[@]} - 1]}" "$val"
    fi
    prev=("${parts[@]}")
  done
}

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
      if ((${#OV[@]} == 0)); then printf '{}\n'; else emit_overrides; fi
    } >"$file"
  )
  ok "Answers saved to $file"
}

wizard_components() {
  heading "Step 3/9 - Components"
  note "CM MES v12 needs Kafka, ClickHouse and S3 storage. Skip one only if you already have it."
  local c ans any=false
  while true; do
    for c in "${COMPONENTS[@]}"; do
      local def=y; [[ "${V[$c.enabled]}" == false ]] && def=n
      ask_yn ans "Install $(component_title "$c")?" "$def"
      W[$c.enabled]=$ans
      $ans && any=true
    done
    $any && break
    warn "Choose at least one component."
  done
}

wizard_tls() {
  heading "Step 4/9 - Certificates (TLS)"
  note "All connections are encrypted. Choose where the certificates come from:"
  local -a opts=("auto|generated automatically, signed by one CA created now (recommended)"
                 "existing|you already created Secrets with tls.crt, tls.key and ca.crt")
  $HAS_CERT_MANAGER && opts+=("certManager|issued by cert-manager (installed in this cluster)")
  local def=${V[global.tls.mode]}
  [[ "$def" == certManager ]] && ! $HAS_CERT_MANAGER && def=auto
  ask_choice "W[global.tls.mode]" "Certificate mode" "$def" "${opts[@]}"
  case "${W[global.tls.mode]}" in
    auto)
      note "A CA Secret '${V[global.namePrefix]}-ca' is created (RSA 4096, valid 10 years) if it does not exist."
      note "install.sh saves its certificate as <component>-ca.crt for the CM MES installer." ;;
    existing)
      note "Each Secret must have tls.crt, tls.key and ca.crt, and the certificate must be valid for the"
      note "service names (<prefix>-<component>.$NAMESPACE.svc and *.<prefix>-<component>-headless...)."
      [[ "${W[kafka.enabled]}" == true ]] && ask_existing_secret kafka.tls.existingSecret "Kafka server certificate Secret"
      [[ "${W[clickhouse.enabled]}" == true ]] && ask_existing_secret clickhouse.tls.existingSecret "ClickHouse server certificate Secret"
      true ;;
    certManager)
      while true; do
        ask "W[global.tls.certManager.issuerName]" "cert-manager issuer name" "${V[global.tls.certManager.issuerName]:-}"
        [[ -n "${W[global.tls.certManager.issuerName]}" ]] && break
        warn "The issuer name is required."
      done
      ask_choice "W[global.tls.certManager.issuerKind]" "Issuer kind" "${V[global.tls.certManager.issuerKind]:-ClusterIssuer}" \
        "ClusterIssuer|cluster-wide issuer" "Issuer|issuer in namespace $NAMESPACE"
      local kind=${W[global.tls.certManager.issuerKind],,}
      if $CLUSTER_OK && ! kcn get "$kind.cert-manager.io" "${W[global.tls.certManager.issuerName]}" >/dev/null 2>&1; then
        warn "Could not find $kind '${W[global.tls.certManager.issuerName]}' (or no permission to read it). Check the name."
      fi ;;
  esac
}

# ask_existing_secret <values path> <label>
ask_existing_secret() {
  local path=$1 label=$2 name
  while true; do
    ask name "$label" "${V[$path]:-}"
    if is_secret_name "$name"; then break; fi
    warn "Type the name of a Secret in namespace $NAMESPACE."
  done
  W[$path]=$name
  check_tls_secret "$name"
}

check_tls_secret() {
  $CLUSTER_OK || return 0
  local keys
  if ! keys="$(kcn get secret "$1" -o 'jsonpath={.data}' 2>/dev/null)"; then
    warn "Secret '$1' was not found in namespace $NAMESPACE. Create it before the installation starts."
    return 0
  fi
  local k
  for k in tls.crt tls.key ca.crt; do
    [[ "$keys" == *"\"$k\""* ]] || warn "Secret '$1' has no '$k' key."
  done
}

wizard_kafka() {
  [[ "${W[kafka.enabled]}" == true ]] || return 0
  heading "Step 5/9 - Kafka authentication"
  note "How CM MES logs in to Kafka."
  ask_choice "W[kafka.auth.method]" "Kafka authentication" "${V[kafka.auth.method]}" \
    "sasl|SASL_SSL Plain: user name and password over TLS (recommended)" \
    "mtls|mutual TLS: a client certificate (files are saved for the MES installer)"
  if [[ "${W[kafka.auth.method]}" == mtls && "${W[global.tls.mode]}" == existing ]]; then
    ask_existing_secret kafka.tls.existingClientSecret "Kafka client (CM MES) certificate Secret"
  fi
}

wizard_s3() {
  [[ "${W[s3.enabled]}" == true ]] || return 0
  heading "Step 6/9 - S3 storage"
  if $HAS_OBC && ((${#RGW_CLASSES[@]} > 0)); then
    note "A Ceph RGW object store was found in this cluster. You can use it instead of installing RustFS."
    ask_choice "W[s3.provider]" "S3 provider" "${V[s3.provider]}" \
      "rustfs|install RustFS here, distributed over ${V[s3.rustfs.replicas]:-3} pods (recommended)" \
      "rgw|use the existing Ceph RGW (a bucket is requested with an ObjectBucketClaim)"
  else
    note "RustFS (S3 compatible) is installed, distributed over ${V[s3.rustfs.replicas]:-3} pods."
    [[ "${V[s3.provider]}" == rgw ]] && warn "s3.provider=rgw in values.yaml, but no Ceph RGW bucket StorageClass was found: using RustFS."
    W[s3.provider]=rustfs
  fi
  if [[ "${W[s3.provider]}" == rgw ]]; then
    local -a opts=() s
    local def=${RGW_CLASSES[0]}
    for s in "${RGW_CLASSES[@]}"; do opts+=("$s|"); [[ "$s" == "${V[s3.rgw.storageClass]:-}" ]] && def=$s; done
    ask_choice "W[s3.rgw.storageClass]" "Bucket StorageClass" "$def" "${opts[@]}"
  elif [[ "${W[global.tls.mode]}" == existing ]]; then
    ask_existing_secret s3.rustfs.tls.existingSecret "RustFS server certificate Secret"
  fi
}

# Provisioner of a StorageClass ("" = cluster default). Empty when unknown.
sc_provisioner() {
  local want=${1:-$DEFAULT_SC} s name prov isdef
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
  local sc=${1-${V[s3.rustfs.storage.storageClass]:-}}
  [[ -n "$sc" ]] || sc=${2-${V[global.storageClass]:-}}
  printf '%s' "$sc"
}

wizard_rustfs_disks() {
  local sc prov choice
  W[s3.rustfs.storage.storageClass]=${V[s3.rustfs.storage.storageClass]:-}
  W[s3.rustfs.allowSharedDisks]=${V[s3.rustfs.allowSharedDisks]:-false}
  while true; do
    sc="$(rustfs_storage_class "${W[s3.rustfs.storage.storageClass]}" "${W[global.storageClass]}")"
    prov="$(sc_provisioner "$sc")"
    if [[ -z "$prov" ]] || ! is_shared_disk_provisioner "$prov"; then return 0; fi
    [[ "${W[s3.rustfs.allowSharedDisks]}" == true ]] && return 0
    warn "StorageClass '${sc:-$DEFAULT_SC}' ($prov) usually puts both RustFS volumes of a pod on the"
    warn "same disk. RustFS refuses that: one disk failure would lose several drives at once."
    note "Use block storage that gives every volume its own disk: Ceph RBD, cloud disks (EBS, Azure Disk,"
    note "GCE PD), vSphere, Longhorn..."
    local -a opts=()
    ((${#STORAGE_CLASSES[@]} > 1)) && opts+=("other|choose another StorageClass for RustFS only")
    opts+=("allow|allow shared disks anyway (s3.rustfs.allowSharedDisks=true; NOT for production)")
    ask_choice choice "What do you want to do?" "${opts[0]%%|*}" "${opts[@]}"
    if [[ "$choice" == allow ]]; then W[s3.rustfs.allowSharedDisks]=true; return 0; fi
    local -a scs=() s name prov2 isdef
    for s in "${STORAGE_CLASSES[@]}"; do
      IFS='|' read -r name prov2 isdef <<<"$s"
      scs+=("$name|$prov2")
    done
    ask_choice "W[s3.rustfs.storage.storageClass]" "StorageClass for the RustFS volumes" "${scs[0]%%|*}" "${scs[@]}"
  done
}

wizard_storage() {
  heading "Step 7/9 - Storage and images"
  local -a opts=() s
  local def="" name prov isdef
  if ((${#STORAGE_CLASSES[@]} > 0)); then
    [[ -n "$DEFAULT_SC" ]] && opts+=("|cluster default ($DEFAULT_SC)")
    for s in "${STORAGE_CLASSES[@]}"; do
      IFS='|' read -r name prov isdef <<<"$s"
      if [[ "$isdef" == true ]]; then opts+=("$name|$prov (default)"); else opts+=("$name|$prov"); fi
    done
    def=${V[global.storageClass]:-}
    [[ -z "$def" && -z "$DEFAULT_SC" ]] && def=${STORAGE_CLASSES[0]%%|*}
    note "Data volumes need a StorageClass with ReadWriteOnce volumes, ideally block storage"
    note "(Ceph RBD, cloud disks, vSphere...). NFS and CephFS are not recommended for databases."
    ask_choice "W[global.storageClass]" "StorageClass for the data volumes" "$def" "${opts[@]}"
  else
    ask "W[global.storageClass]" "StorageClass for the data volumes (empty = cluster default)" "${V[global.storageClass]:-}"
  fi

  if [[ "${W[s3.enabled]}" == true && "${W[s3.provider]}" == rustfs ]]; then wizard_rustfs_disks; fi

  note "Size of each data volume (e.g. 50Gi, 1Ti). It can be increased later (never decreased)"
  note "when the StorageClass allows volume expansion; install.sh then resizes the volumes."
  [[ "${W[kafka.enabled]}" == true ]] && ask_size kafka.storage.size "Kafka, per broker (x${V[kafka.replicas]:-3})" kafka data
  if [[ "${W[clickhouse.enabled]}" == true ]]; then
    ask_size clickhouse.storage.size "ClickHouse, per server (x${V[clickhouse.replicas]:-2})" clickhouse data
    ask_size clickhouse.keeper.storage.size "ClickHouse Keeper, per server (x${V[clickhouse.keeper.replicas]:-3})" keeper data
  fi
  if [[ "${W[s3.enabled]}" == true && "${W[s3.provider]}" == rustfs ]]; then
    ask_size s3.rustfs.storage.size "RustFS, per volume (x${V[s3.rustfs.replicas]:-3} pods x ${V[s3.rustfs.volumesPerPod]:-2} volumes)" s3 data-0
  fi

  W[global.podAntiAffinity]=${V[global.podAntiAffinity]}
  if [[ "$NODE_COUNT" != unknown ]] && (( NODE_COUNT < 3 )); then
    local soft
    warn "This cluster has fewer than 3 schedulable nodes."
    ask_yn soft "Allow several pods of a component on the same node (NOT highly available; test only)?" n
    $soft && W[global.podAntiAffinity]=soft
  fi

  local private
  note "Air-gapped clusters pull the images from a private registry that mirrors them."
  ask_yn private "Use a private image registry?" "$([[ -n "${V[global.imageRegistry]:-}" ]] && echo y || echo n)"
  if $private; then
    local reg
    while true; do
      ask reg "Registry and path (e.g. registry.example.com/mirror)" "${V[global.imageRegistry]:-}"
      reg=${reg#http://}; reg=${reg#https://}; reg=${reg%/}
      [[ -n "$reg" && "$reg" != *" "* ]] && break
      warn "Type the registry host, optionally with a path."
    done
    W[global.imageRegistry]=$reg
    ask "W[global.imagePullSecrets]" "Image pull Secret name (empty = none)" "${V[global.imagePullSecrets]%%,*}"
  else
    W[global.imageRegistry]=""
    W[global.imagePullSecrets]=""
  fi
}

# Size of volume <vct> in the live StatefulSet <prefix>-<name> ("" when not installed).
live_volume_size() {
  kcn get statefulset "${V[global.namePrefix]}-$1" \
    -o "jsonpath={.spec.volumeClaimTemplates[?(@.metadata.name==\"$2\")].spec.resources.requests.storage}" 2>/dev/null | tr -d '\r' || true
}

# ask_size <values path> <label> [<statefulset name> <volume>]: the default is the size
# of the existing installation, so that pressing Enter never resizes a volume.
ask_size() {
  local path=$1 label=$2 val def=${V[$1]:-} live=""
  [[ -n "${3:-}" ]] && live="$(live_volume_size "$3" "$4")"
  if [[ -n "$live" ]]; then
    def=$live
    label="$label, currently $live"
  fi
  while true; do
    ask val "$label" "$def"
    is_size "$val" && break
    warn "Use a number followed by Mi, Gi or Ti, e.g. 100Gi."
  done
  W[$path]=$val
}

wizard_observability() {
  heading "Step 8/9 - Monitoring (optional)"
  note "An OpenTelemetry collector can send the metrics of these components to an OTLP/HTTP"
  note "endpoint, for example the CM Observability service. Leave empty to skip."
  local ep
  while true; do
    ask ep "OTLP/HTTP endpoint (e.g. https://otlp.example.com:4318)" "${V[observability.otlpEndpoint]:-}"
    [[ -z "$ep" || "$ep" =~ ^https?://[^[:space:]]+$ ]] && break
    warn "The endpoint must start with https:// (or http://)."
  done
  W[observability.otlpEndpoint]=$ep
  W[observability.headers]=""
  W[observability.tls.ca]=""
  W[observability.tls.insecureSkipVerify]=${V[observability.tls.insecureSkipVerify]:-false}
  if [[ -z "$ep" ]]; then
    warn "No monitoring will be installed. Without it, problems in Kafka, ClickHouse or S3 are"
    warn "only noticed when CM MES fails. We recommend CM Observability: $CM_OBSERVABILITY_URL"
    return 0
  fi
  local auth hname hvalue old_headers=${V[observability.headers]:-}
  ask_yn auth "Does the endpoint need an authentication header (e.g. an API token)?" "$([[ -n "$old_headers" ]] && echo y || echo n)"
  if $auth; then
    if [[ -n "$old_headers" ]]; then
      local keep
      ask_yn keep "Keep the current header(s) ($old_headers)?" y
      if $keep; then W[observability.headers]=${V[observability.headers@json]}; auth=false; fi
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
    W[observability.headers]="{$(yaml_str "$hname"): $(yaml_str "$hvalue")}"
  fi
  if [[ "$ep" == https://* ]]; then
    local caf old_ca=${V[observability.tls.ca]:-}
    while true; do
      if [[ -n "$old_ca" ]]; then
        ask caf "File with the endpoint's CA certificate (PEM; Enter = keep the current one, '-' = none)" ""
        if [[ -z "$caf" ]]; then W[observability.tls.ca]=${V[observability.tls.ca@json]}; break; fi
        [[ "$caf" == - ]] && { W[observability.tls.ca]='""'; break; }
      else
        ask caf "File with the endpoint's CA certificate (PEM; empty = public CAs)" ""
        [[ -z "$caf" ]] && break
      fi
      if [[ -f "$caf" ]] && grep -q 'BEGIN CERTIFICATE' "$caf"; then
        W[observability.tls.ca]="|"$'\n'"$(tr -d '\r' <"$caf")"; break
      fi
      warn "'$caf' is not a readable PEM certificate file."
    done
    local skip
    ask_yn skip "Skip the endpoint certificate validation (testing only)?" "$([[ "${W[observability.tls.insecureSkipVerify]}" == true ]] && echo y || echo n)"
    W[observability.tls.insecureSkipVerify]=$skip
  fi
}

run_wizard() {
  wizard_components
  wizard_tls
  wizard_kafka
  wizard_s3
  wizard_storage
  wizard_observability

  # Translate the answers into overrides of values.yaml.
  OV=()
  local c
  for c in "${COMPONENTS[@]}"; do set_ov "$c.enabled" "${W[$c.enabled]}" "${W[$c.enabled]}"; done
  set_ov global.tls.mode "$(yaml_str "${W[global.tls.mode]}")" "${W[global.tls.mode]}"
  if [[ "${W[global.tls.mode]}" == certManager ]]; then
    set_ov global.tls.certManager.issuerName "$(yaml_str "${W[global.tls.certManager.issuerName]}")" "${W[global.tls.certManager.issuerName]}"
    set_ov global.tls.certManager.issuerKind "$(yaml_str "${W[global.tls.certManager.issuerKind]}")" "${W[global.tls.certManager.issuerKind]}"
  fi
  local p
  for p in kafka.tls.existingSecret kafka.tls.existingClientSecret clickhouse.tls.existingSecret s3.rustfs.tls.existingSecret \
           kafka.auth.method s3.provider s3.rgw.storageClass kafka.storage.size clickhouse.storage.size \
           clickhouse.keeper.storage.size s3.rustfs.storage.size global.podAntiAffinity global.storageClass \
           s3.rustfs.storage.storageClass global.imageRegistry observability.otlpEndpoint; do
    [[ -n "${W[$p]+x}" ]] && set_ov "$p" "$(yaml_str "${W[$p]}")" "${W[$p]}"
  done
  if [[ -n "${W[global.imagePullSecrets]:-}" ]]; then
    set_ov global.imagePullSecrets "[$(yaml_str "${W[global.imagePullSecrets]}")]" "${W[global.imagePullSecrets]}"
  elif [[ -n "${B[global.imagePullSecrets]:-}" && "${W[global.imageRegistry]:-}" == "" ]]; then
    OV[global.imagePullSecrets]="[]"
  fi
  [[ -n "${W[observability.headers]}" ]] && OV[observability.headers]=${W[observability.headers]}
  [[ -n "${W[observability.tls.ca]}" ]] && OV[observability.tls.ca]=${W[observability.tls.ca]}
  set_ov observability.tls.insecureSkipVerify "${W[observability.tls.insecureSkipVerify]}" "${W[observability.tls.insecureSkipVerify]}"
  if [[ -n "${W[s3.rustfs.allowSharedDisks]+x}" ]]; then
    set_ov s3.rustfs.allowSharedDisks "${W[s3.rustfs.allowSharedDisks]}" "${W[s3.rustfs.allowSharedDisks]}"
  fi
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
show_summary() {
  $INTERACTIVE || heading "Summary"
  local p=${V[global.namePrefix]} sc=${V[global.storageClass]:-}
  [[ -n "$sc" ]] || sc="cluster default${DEFAULT_SC:+ ($DEFAULT_SC)}"
  printf '  %-22s %s\n' "Namespace:" "$NAMESPACE" "Name prefix:" "$p" "TLS certificates:" "${V[global.tls.mode]}"
  if enabled kafka; then
    printf '  %-22s %s\n' "Kafka:" "${V[kafka.replicas]:-3} brokers, ${V[kafka.storage.size]:-?} each, auth ${V[kafka.auth.method]} (release $p-kafka)"
  else printf '  %-22s %s\n' "Kafka:" "not installed"; fi
  if enabled clickhouse; then
    printf '  %-22s %s\n' "ClickHouse:" "${V[clickhouse.replicas]:-2} servers x ${V[clickhouse.storage.size]:-?}, ${V[clickhouse.keeper.replicas]:-3} keepers x ${V[clickhouse.keeper.storage.size]:-?} (release $p-clickhouse)"
  else printf '  %-22s %s\n' "ClickHouse:" "not installed"; fi
  if enabled s3; then
    if [[ "${V[s3.provider]}" == rgw ]]; then
      printf '  %-22s %s\n' "S3:" "Ceph RGW bucket (StorageClass ${V[s3.rgw.storageClass]:-?}) (release $p-s3)"
    else
      printf '  %-22s %s\n' "S3:" "RustFS, ${V[s3.rustfs.replicas]:-3} pods x ${V[s3.rustfs.volumesPerPod]:-2} volumes x ${V[s3.rustfs.storage.size]:-?} (release $p-s3)"
    fi
  else printf '  %-22s %s\n' "S3:" "not installed"; fi
  if otel_enabled; then
    printf '  %-22s %s\n' "Monitoring:" "OpenTelemetry collector -> ${V[observability.otlpEndpoint]} (release $p-otel)"
  else
    printf '  %-22s %s\n' "Monitoring:" "none"
  fi
  printf '  %-22s %s\n' "StorageClass:" "$sc" "Pod spreading:" "${V[global.podAntiAffinity]}"
  [[ -n "${V[global.imageRegistry]:-}" ]] && printf '  %-22s %s\n' "Image registry:" "${V[global.imageRegistry]} (pull Secret: ${V[global.imagePullSecrets]:-none})"
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
  [[ "${V[global.tls.mode]}" == certManager ]] && require_can_i create certificates.cert-manager.io
  if enabled s3 && [[ "${V[s3.provider]}" == rgw ]]; then require_can_i create objectbucketclaims.objectbucket.io; fi
  if enabled s3 && [[ "${V[s3.provider]}" == rustfs && "${V[s3.rustfs.allowSharedDisks]:-false}" != true ]]; then
    local rsc rprov
    rsc="$(rustfs_storage_class)"; rprov="$(sc_provisioner "$rsc")"
    if [[ -n "$rprov" ]] && is_shared_disk_provisioner "$rprov"; then
      warn "RustFS StorageClass '${rsc:-$DEFAULT_SC}' ($rprov) usually puts both volumes of a pod on one disk:"
      warn "RustFS will refuse to start. Use block storage (s3.rustfs.storage.storageClass), or for"
      warn "non-production only set s3.rustfs.allowSharedDisks: true."
    fi
  fi
  if [[ "${V[global.tls.mode]}" == certManager ]] && ! $HAS_CERT_MANAGER; then
    die "global.tls.mode=certManager, but cert-manager is not installed in this cluster."
  fi
  if enabled s3 && [[ "${V[s3.provider]}" == rgw ]]; then
    $HAS_OBC || die "s3.provider=rgw, but the ObjectBucketClaim API (objectbucket.io) is not available in this cluster."
    local found=false s
    for s in ${RGW_CLASSES[@]+"${RGW_CLASSES[@]}"}; do [[ "$s" == "${V[s3.rgw.storageClass]}" ]] && found=true; done
    $found || warn "s3.rgw.storageClass '${V[s3.rgw.storageClass]}' is not a known Ceph RGW bucket StorageClass (found: ${RGW_CLASSES[*]:-none})."
  fi
  if [[ "${V[global.tls.mode]}" == existing ]]; then
    local p
    for p in kafka.tls.existingSecret kafka.tls.existingClientSecret clickhouse.tls.existingSecret s3.rustfs.tls.existingSecret; do
      [[ -n "${V[$p]:-}" ]] && enabled "${p%%.*}" && check_tls_secret "${V[$p]}"
    done
  fi
  if [[ "$NODE_COUNT" != unknown ]] && (( NODE_COUNT < 3 )) && [[ "${V[global.podAntiAffinity]}" == hard ]]; then
    warn "Fewer than 3 schedulable nodes with global.podAntiAffinity=hard: some pods will stay Pending."
  fi
  if [[ -n "${V[global.storageClass]:-}" ]] && ((${#STORAGE_CLASSES[@]} > 0)); then
    local s found=false
    for s in "${STORAGE_CLASSES[@]}"; do [[ "${s%%|*}" == "${V[global.storageClass]}" ]] && found=true; done
    $found || warn "StorageClass '${V[global.storageClass]}' was not found in the cluster."
  elif [[ -z "${V[global.storageClass]:-}" && -z "$DEFAULT_SC" ]] && ((${#STORAGE_CLASSES[@]} > 0)); then
    warn "global.storageClass is empty and the cluster has no default StorageClass: volumes will stay Pending."
  fi
  if [[ -n "${V[global.imagePullSecrets]:-}" ]]; then
    local s
    IFS=, read -r -a _ips <<<"${V[global.imagePullSecrets]}"
    for s in "${_ips[@]}"; do
      kcn get secret "$s" >/dev/null 2>&1 || warn "Image pull Secret '$s' was not found in namespace $NAMESPACE."
    done
  fi
  true
}

# ----------------------------------------------------------------------------
# Installation
# ----------------------------------------------------------------------------
selected_releases() {   # prints the components to install, in order
  local c
  for c in "${COMPONENTS[@]}"; do enabled "$c" && echo "$c"; done
  otel_enabled && echo otel
  true
}

build_dependencies() {
  local comp=$1 out
  [[ -f "$CHARTS_DIR/$comp/Chart.yaml" ]] || die "Chart $CHARTS_DIR/$comp is missing. Get the complete installer package."
  if ! out="$("$HELM" dependency update --skip-refresh "$CHARTS_DIR/$comp" 2>&1)"; then
    err "helm dependency update failed for charts/$comp:"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
    exit 1
  fi
}

ensure_ca() {
  local name=${V[global.tls.caSecret]:-}
  [[ -n "$name" ]] || name="${V[global.namePrefix]}-ca"
  if kcn get secret "$name" >/dev/null 2>&1; then
    ok "CA Secret '$name' already exists: reused (never overwritten)"
    return 0
  fi
  have openssl || die "openssl is needed to create the CA Secret '$name'. Install it, or use global.tls.mode=existing/certManager."
  make_tmp
  local d="$TMP_DIR/ca" cn="${V[global.namePrefix]} CM MES dependencies CA"
  mkdir -p "$d"
  # The subject is given in a config file instead of "-subj /CN=...": Git Bash on Windows
  # would turn "/CN=..." into a Windows path. A config file also works with every OpenSSL
  # (1.1, 3.x, LibreSSL on macOS) and sets proper CA extensions.
  cat >"$d/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[dn]
CN = $cn
[v3_ca]
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
EOF
  info "Creating the CA (RSA 4096, valid 10 years). This can take a few seconds..."
  local out
  if ! out="$( (umask 077; openssl req -x509 -new -newkey rsa:4096 -nodes -sha256 -days 3650 \
          -config "$d/ca.cnf" -keyout "$d/ca.key" -out "$d/ca.crt") 2>&1)"; then
    err "openssl failed:"; printf '%s\n' "$out" | sed 's/^/         /' >&2; exit 1
  fi
  if ! out="$(kcn create secret tls "$name" --cert "$d/ca.crt" --key "$d/ca.key" 2>&1)"; then
    err "Could not create the CA Secret '$name':"; printf '%s\n' "$out" | sed 's/^/         /' >&2; exit 1
  fi
  kcn label secret "$name" app.kubernetes.io/part-of=cm-mes-dependencies >/dev/null 2>&1 || true
  rm -f "$d/ca.key"
  ok "CA Secret '$name' created. Back it up: all certificates are signed by it."
}

# Prints "<ready>/<total>" pods of a release.
pods_ready() {
  local out total=0 ready=0 line
  out="$(kcn get pods -l "app.kubernetes.io/instance=$1" -o 'jsonpath={range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -n "$line" ]] || { [[ -z "$out" ]] && continue; total=$((total + 1)); continue; }
    total=$((total + 1))
    [[ "$line" != *false* ]] && ready=$((ready + 1))
  done <<<"$out"
  printf '%d/%d' "$ready" "$total"
}

# run_with_progress <release> <log> <cmd...>: runs a command, showing elapsed time and pods.
run_with_progress() {
  local rel=$1 log=$2; shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! start=$SECONDS last=0 rc=0 el
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    el=$((SECONDS - start))
    if [[ -t 1 ]]; then
      if (( el - last >= 10 )); then last=$el; printf '\r  ... %dm%02ds elapsed, pods ready: %-8s' $((el / 60)) $((el % 60)) "$(pods_ready "$rel")"; fi
    elif (( el - last >= 60 )); then
      last=$el; printf '  ... %dm elapsed, pods ready: %s\n' $((el / 60)) "$(pods_ready "$rel")"
    fi
  done
  wait "$pid" || rc=$?
  [[ -t 1 ]] && printf '\r%*s\r' 60 ''
  return "$rc"
}

diagnose() {
  local rel=$1 log=$2
  heading "What went wrong"
  if [[ -s "$log" ]]; then
    info "Last lines of the helm output (${log#"$PWD"/}):"
    tail -n 15 "$log" | sed 's/^/    /'
  fi
  if grep -q 'another operation (install/upgrade/rollback) is in progress' "$log" 2>/dev/null; then
    warn "A previous installation of $rel was interrupted. Run: $HELM rollback $rel -n $NAMESPACE"
    warn "(or '$HELM uninstall $rel -n $NAMESPACE' if it was never installed successfully), then retry."
  fi
  $CLUSTER_OK || return 0

  local out name phase states
  out="$(kcn get pods -l "app.kubernetes.io/instance=$rel" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.initContainerStatuses[*]}{.ready}{":"}{.state.waiting.reason}{" "}{end}{range .status.containerStatuses[*]}{.ready}{":"}{.state.waiting.reason}{" "}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    info ""
    info "Pods of $rel:"
    kcn get pods -l "app.kubernetes.io/instance=$rel" -o wide 2>/dev/null | sed 's/^/    /' || true
  fi
  local hint_pending=false
  while IFS='|' read -r name phase states; do
    [[ -n "$name" ]] || continue
    states=${states%$'\r'}
    if [[ "$phase" == Pending && -z "$(trim "$states")" ]]; then
      hint_pending=true
      local ev
      ev="$(kcn get events --field-selector "involvedObject.name=$name,reason=FailedScheduling" -o 'jsonpath={range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | tail -n 1 || true)"
      warn "Pod $name cannot be scheduled${ev:+: $ev}"
      case "$ev" in
        *nsufficient*) info "    -> not enough CPU/memory on the nodes: add nodes or lower the resources in charts/<name>/values.yaml." ;;
        *anti-affinity*) info "    -> one pod per node is required and there are not enough nodes (need >= 3). For tests only: global.podAntiAffinity: soft" ;;
        *unbound*PersistentVolumeClaim*|*persistentvolumeclaim*) info "    -> its data volume is not bound yet (see the volumes below)." ;;
        *taint*) info "    -> the nodes have taints: set global.tolerations or global.nodeSelector." ;;
      esac
    fi
    case "$states" in
      *ImagePullBackOff*|*ErrImagePull*|*InvalidImageName*)
        warn "Pod $name cannot pull its image. Check internet access or global.imageRegistry / global.imagePullSecrets."
        info "    kubectl -n $NAMESPACE describe pod $name" ;;
      *CreateContainerConfigError*)
        warn "Pod $name references a missing Secret or ConfigMap (e.g. a TLS Secret in mode 'existing')."
        info "    kubectl -n $NAMESPACE describe pod $name" ;;
      *CrashLoopBackOff*|*Error*)
        warn "Pod $name keeps crashing. See its logs:"
        info "    kubectl -n $NAMESPACE logs $name --all-containers --previous" ;;
    esac
    if [[ "$phase" == Running && "$states" == *false* && "$states" != *BackOff* ]]; then
      warn "Pod $name is running but not ready yet. It may need more time, or see: kubectl -n $NAMESPACE logs $name"
    fi
  done <<<"$out"

  local pvcs pvc pphase psc
  pvcs="$(kcn get pvc -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.storageClassName}{"\n"}{end}' 2>/dev/null || true)"
  while IFS='|' read -r pvc pphase psc; do
    psc=${psc%$'\r'}
    [[ "$pvc" == *"${V[global.namePrefix]}"* && "$pphase" == Pending ]] || continue
    warn "Volume $pvc is Pending (StorageClass: ${psc:-cluster default})."
    info "    -> check that the StorageClass exists and can provision volumes: kubectl -n $NAMESPACE describe pvc $pvc"
  done <<<"$pvcs"

  info ""
  info "Recent warnings in namespace $NAMESPACE:"
  kcn get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 | sed 's/^/    /' || true
  info ""
  info "More details:  kubectl -n $NAMESPACE describe pod <pod>   /   kubectl -n $NAMESPACE logs <pod>"
  $hint_pending && info "Pending pods usually mean: not enough nodes, not enough CPU/memory, or volumes not provisioned."
  info "Fix the cause and run install.sh again with the same options: it continues where it stopped."
}

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

  apply_resize "$comp"
  info "Installing $(component_title "$comp") (release $rel). This can take up to $HELM_TIMEOUT..."
  if run_with_progress "$rel" "$log" "$HELM" upgrade --install "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" \
      "${vargs[@]}" --wait --timeout "$HELM_TIMEOUT"; then
    ok "$(component_title "$comp") is ready (log: output/logs/$rel.log)"
  else
    err "$(component_title "$comp") did not become ready."
    diagnose "$rel" "$log"
    exit 1
  fi
  if [[ "$comp" == s3 && "${V[s3.provider]}" == rgw ]]; then
    wait_obc_bound 600 || { diagnose_obc; exit 1; }
  fi
}

obc_name() { printf '%s-s3' "${V[global.namePrefix]}"; }

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
  info "    kubectl get storageclass ${V[s3.rgw.storageClass]}"
  kcn describe objectbucketclaim "$name" 2>/dev/null | tail -n 15 | sed 's/^/    /' || true
}

# ----------------------------------------------------------------------------
# Checks against the live installation (upgrades)
# ----------------------------------------------------------------------------
declare -a RESIZE_PLAN=()   # "comp|statefulset|template|new size"
declare -A SAVED_V=()

save_V()    { local k; SAVED_V=(); for k in "${!V[@]}"; do SAVED_V[$k]=${V[$k]}; done; }
restore_V() { local k; V=(); for k in "${!SAVED_V[@]}"; do V[$k]=${SAVED_V[$k]}; done; }

prepare_charts() {
  $CHARTS_READY && return 0
  local -a comps=()
  local c
  mapfile -t comps < <(selected_releases)
  for c in "${comps[@]}"; do build_dependencies "$c"; done
  ok "Charts prepared: ${comps[*]}"
  CHARTS_READY=true
}

release_exists() { "$HELM" status "$1" -n "$NAMESPACE" >/dev/null 2>&1; }

# Quantity (50Gi, 1.5Ti, 500M...) in bytes; -1 when it cannot be parsed.
to_bytes() {
  awk -v q="$1" 'BEGIN {
    n = q; u = q; sub(/[A-Za-z]+$/, "", n); sub(/^[0-9.]+/, "", u)
    m["Ki"]=1024; m["Mi"]=1024^2; m["Gi"]=1024^3; m["Ti"]=1024^4; m["Pi"]=1024^5
    m["k"]=1e3; m["M"]=1e6; m["G"]=1e9; m["T"]=1e12; m["P"]=1e15; m[""]=1
    if (n == "" || !(u in m)) { print -1; exit }
    printf "%.0f\n", n * m[u] }'
}

# Prints "statefulset|template|size|storageClassName" for every volumeClaimTemplate
# of the StatefulSets in a rendered manifest (helm template output).
rendered_vcts() {
  awk '
    function unq(s) { gsub(/^["\047]|["\047]$/, "", s); return s }
    function val(l) { sub(/^[^:]*:[ ]*/, "", l); return unq(l) }
    function flush() { if (item && sts != "") print sts "|" vname "|" size "|" sc; item = 0; vname = ""; size = ""; sc = "" }
    /^---/ { flush(); kind = ""; sts = ""; inmeta = 0; invct = 0; next }
    /^kind: / { kind = $2; next }
    /^metadata:/ { inmeta = 1; next }
    inmeta && /^  name: / { if (sts == "") sts = val($0); inmeta = 0; next }
    /^[^ #]/ { inmeta = 0 }
    kind != "StatefulSet" { next }
    /^  volumeClaimTemplates:/ { invct = 1; next }
    invct {
      if ($0 !~ /[^ ]/) next
      match($0, /^ */); ind = RLENGTH
      if (ind <= 2 && $0 !~ /^  - /) { flush(); invct = 0; next }
      if ($0 ~ /^ *- / && ind <= 4) { flush(); item = 1 }
      line = $0; sub(/^ *(- )?/, "", line)
      if (line ~ /^name: / && vname == "") vname = val(line)
      else if (line ~ /^storageClassName:/) sc = val(line)
      else if (line ~ /^storage: /) size = val(line)
    }
    END { flush() }' "$1"
}

# Compares the volumes of the StatefulSets that already exist with the new values.
# Fills RESIZE_PLAN; stops (before anything is changed) on changes Kubernetes forbids.
check_volumes() {
  local comp=$1 rel rendered line sts vct size sc live lsize lsc
  rel="$(release_name "$comp")"
  make_tmp
  rendered="$TMP_DIR/check-$rel.yaml"
  local -a vargs=()
  local f
  for f in "${VALUES_FILES[@]}"; do vargs+=(-f "$f"); done
  if ! "$HELM" template "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" "${vargs[@]}" >"$rendered" 2>/dev/null; then
    warn "$(component_title "$comp"): could not render the chart to compare the volumes (see the install step)."
    return 0
  fi
  while IFS='|' read -r sts vct size sc; do
    [[ -n "$sts" && -n "$vct" ]] || continue
    live="$(kcn get statefulset "$sts" -o "jsonpath={range .spec.volumeClaimTemplates[*]}{.metadata.name}{\"|\"}{.spec.resources.requests.storage}{\"|\"}{.spec.storageClassName}{\"\\n\"}{end}" 2>/dev/null | tr -d '\r' | grep "^$vct|" || true)"
    [[ -n "$live" ]] || continue                     # new StatefulSet or new volume: nothing to compare
    IFS='|' read -r _ lsize lsc <<<"$live"
    if [[ "$lsc" != "$sc" ]]; then
      err "The StorageClass of the '$vct' volumes of $sts cannot be changed (installed: '${lsc:-cluster default}', new: '${sc:-cluster default}')."
      info "Kubernetes does not allow it for existing StatefulSets. Keep the installed value in your values file"
      info "(global.storageClass / <component>.storage.storageClass). Nothing was changed."
      exit 1
    fi
    local lb nb
    lb="$(to_bytes "$lsize")"; nb="$(to_bytes "$size")"
    if [[ "$lb" == -1 || "$nb" == -1 ]]; then
      warn "$sts: cannot compare the volume sizes '$lsize' and '$size'; continuing."; continue
    fi
    (( nb == lb )) && continue
    if (( nb < lb )); then
      err "The '$vct' volumes of $sts cannot be made smaller (installed: $lsize, new: $size). Nothing was changed."
      info "Set the size back to $lsize (or larger) in your values file."
      exit 1
    fi
    # Bigger: possible only when the StorageClass allows volume expansion.
    local pvc0 psc exp
    pvc0="$vct-$sts-0"
    psc="$(kcn get pvc "$pvc0" -o 'jsonpath={.spec.storageClassName}' 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$psc" ]] || psc=${sc:-$DEFAULT_SC}
    exp="$(kc get storageclass "$psc" -o 'jsonpath={.allowVolumeExpansion}' 2>/dev/null | tr -d '\r' || true)"
    if [[ "$exp" != true ]]; then
      err "The '$vct' volumes of $sts cannot grow from $lsize to $size: StorageClass '${psc:-?}' does not allow"
      info "volume expansion (allowVolumeExpansion is not true, or it cannot be read). Keep $lsize. Nothing was changed."
      exit 1
    fi
    RESIZE_PLAN+=("$comp|$sts|$vct|$size|$lsize")
  done < <(rendered_vcts "$rendered")
}

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
      if [[ "$p" == "${V[global.namePrefix]}" ]]; then mine=true
      elif [[ " ${others[*]} " != *" $p "* ]]; then others+=("$p"); fi
    fi
  done < <("$HELM" list -n "$NAMESPACE" -q 2>/dev/null || true)
  if ((${#others[@]} > 0)) && ! $mine; then
    heading "Existing installation"
    warn "Namespace $NAMESPACE already has releases with the name prefix: ${others[*]}"
    warn "global.namePrefix is '${V[global.namePrefix]}': this installs a SECOND, separate set (new volumes,"
    warn "new passwords) instead of updating it. To update it, set global.namePrefix: ${others[0]}"
    $DRY_RUN || confirm_or_exit "Install a second set with prefix '${V[global.namePrefix]}'?"
  fi

  # 2. Settings that change how CM MES connects.
  local -a changes=()
  save_V
  local new_tls=${V[global.tls.mode]} new_auth=${V[kafka.auth.method]} new_s3=${V[s3.provider]}
  for c in "${comps[@]}"; do
    rel="$(release_name "$c")"
    release_exists "$rel" || continue
    make_tmp
    "$HELM" get values "$rel" -n "$NAMESPACE" -a -o yaml >"$TMP_DIR/live-$rel.yaml" 2>/dev/null || continue
    read_values "$TMP_DIR/live-$rel.yaml"
    if [[ "$c" != otel && "${V[global.tls.mode]}" != "$new_tls" ]]; then
      changes+=("$(component_title "$c"): TLS mode ${V[global.tls.mode]} -> $new_tls. All its certificates change; CM MES must trust the new CA ($c-ca.crt).")
    fi
    if [[ "$c" == kafka && "${V[kafka.auth.method]}" != "$new_auth" ]]; then
      changes+=("Kafka: authentication ${V[kafka.auth.method]} -> $new_auth. Supported, but CM MES must then use the new values printed at the end.")
    fi
    if [[ "$c" == s3 && "${V[s3.provider]}" != "$new_s3" ]]; then
      changes+=("S3: provider ${V[s3.provider]} -> $new_s3. The data is NOT copied; CM MES starts with an empty bucket.")
    fi
    restore_V
  done
  restore_V
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
    confirm_or_exit "Resize these volumes?"
  fi
}

# Runs the resize planned for one component, just before its upgrade.
apply_resize() {
  local comp=$1 line c sts vct size lsize pvc cur
  local -a done_sts=()
  for line in ${RESIZE_PLAN[@]+"${RESIZE_PLAN[@]}"}; do
    IFS='|' read -r c sts vct size lsize <<<"$line"
    [[ "$c" == "$comp" ]] || continue
    while IFS= read -r pvc; do
      pvc=${pvc%$'\r'}; pvc=${pvc#persistentvolumeclaim/}
      [[ "$pvc" =~ ^$vct-$sts-[0-9]+$ ]] || continue
      cur="$(kcn get pvc "$pvc" -o 'jsonpath={.spec.resources.requests.storage}' 2>/dev/null | tr -d '\r' || true)"
      if [[ -n "$cur" ]] && (( $(to_bytes "$cur") >= $(to_bytes "$size") )); then continue; fi
      kcn patch pvc "$pvc" --type merge -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$size\"}}}}" >/dev/null \
        || die "Could not resize volume $pvc (kubectl -n $NAMESPACE describe pvc $pvc)."
      ok "Volume $pvc: resize to $size requested"
    done < <(kcn get pvc -o name 2>/dev/null || true)
    if [[ " ${done_sts[*]} " != *" $sts "* ]]; then
      kcn delete statefulset "$sts" --cascade=orphan >/dev/null \
        || die "Could not delete StatefulSet $sts (orphan). The volumes were resized; run install.sh again."
      ok "StatefulSet $sts removed (pods keep running); the upgrade recreates it"
      done_sts+=("$sts")
    fi
  done
}

run_install() {
  local -a comps=()
  mapfile -t comps < <(selected_releases)

  heading "Preparing"
  local c
  prepare_charts
  if [[ "${V[global.tls.mode]}" == auto ]]; then
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
safe_name() { local s=$1; printf '%s' "${s//[^A-Za-z0-9._-]/_}"; }

# save_secret_key <secret> <key> <file>
save_secret_key() {
  local data
  data="$(kcn get secret "$1" -o "jsonpath={.data.${2//./\\.}}" 2>/dev/null || true)"
  data=${data%$'\r'}
  if [[ -z "$data" ]]; then warn "Secret $1 has no key '$2' (file $3 not saved)."; return 0; fi
  printf '%s' "$data" | b64d >"$OUTPUT_DIR/$3"
  SAVED_FILES+=("$3")
}

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
  local prefix=${V[global.namePrefix]} out entries=() line name order comp ca files fsecret
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
    [[ "$comp" == s3 && "${V[s3.provider]}" == rgw ]] && continue
    entries+=("$order|secret|$line")
  done <<<"$out"
  if enabled s3 && [[ "${V[s3.provider]}" == rgw ]]; then entries+=("30|rgw|"); fi
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
  local p=${V[global.namePrefix]} c
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
  local p=${V[global.namePrefix]} c rel
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
  enabled s3 && [[ "${V[s3.provider]}" == rgw ]] && \
    info "The Ceph RGW bucket (ObjectBucketClaim $p-s3) is kept as well."
  confirm_or_exit "Uninstall ${present[*]} from namespace $NAMESPACE (context ${KUBE_CONTEXT:-?})? The data volumes are kept"
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
  if enabled s3 && [[ "${V[s3.provider]}" == rgw ]]; then
    info ""
    warn "To delete the Ceph RGW bucket and ALL its data (cannot be undone):"
    info "    kubectl -n $NAMESPACE delete objectbucketclaim $p-s3"
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
parse_args() {
  while (($# > 0)); do
    case "$1" in
      -n|--namespace) [[ $# -ge 2 ]] || die "$1 needs a value"; NAMESPACE=$2; shift 2 ;;
      --namespace=*)  NAMESPACE=${1#*=}; shift ;;
      -f|--values)    [[ $# -ge 2 ]] || die "$1 needs a value"; USER_VALUES=$2; shift 2 ;;
      --values=*)     USER_VALUES=${1#*=}; shift ;;
      -y|--yes)       ASSUME_YES=true; shift ;;
      --dry-run)      DRY_RUN=true; shift ;;
      --print)        ACTION=print; shift ;;
      --uninstall)    ACTION=uninstall; shift ;;
      --timeout)      [[ $# -ge 2 ]] || die "$1 needs a value"; HELM_TIMEOUT=$2; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage >&2; die "Unknown option: $1" ;;
    esac
  done
  [[ "$HELM_TIMEOUT" =~ ^[0-9]+[smh]$|^[0-9]+m[0-9]+s$ ]] || die "--timeout must look like 20m or 1h (got '$HELM_TIMEOUT')."
  [[ -z "$USER_VALUES" || -f "$USER_VALUES" ]] || die "Values file '$USER_VALUES' not found."
}

# The values files passed to every release: values.yaml, then the user's file.
set_values_files() {
  VALUES_FILES=("$BASE_VALUES")
  local extra=$USER_VALUES
  if [[ -z "$extra" && -f "$GENERATED_VALUES" ]] && { [[ "$ACTION" != install ]] || $INTERACTIVE; }; then
    extra=$GENERATED_VALUES
    if $INTERACTIVE; then note "The answers in $GENERATED_VALUES are used as the defaults."
    else note "Using $GENERATED_VALUES (pass -f to use another file)."; fi
  fi
  if [[ -n "$extra" ]] && [[ "$(abs_path "$extra")" != "$(abs_path "$BASE_VALUES")" ]]; then
    VALUES_FILES+=("$extra")
  fi
}

main() {
  parse_args "$@"
  umask 077   # everything written (answers, connection info, keys) is private
  [[ -f "$BASE_VALUES" ]] || die "$BASE_VALUES not found. Run install.sh from the installer folder."
  [[ "$ACTION" == install && -z "$USER_VALUES" ]] && INTERACTIVE=true

  printf '%sCritical Manufacturing MES v12 - external dependencies installer%s\n' "$C_BOLD" "$C_RESET"
  case "$ACTION" in
    print|uninstall)
      heading "Checking prerequisites"
      check_tools
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
    heading "Step 1/9 - Prerequisites"
    note "Answer each question, or press Enter to accept the value in [brackets]."
  else
    heading "Checking prerequisites"
  fi
  check_tools
  if $DRY_RUN && ! $INTERACTIVE; then check_cluster false ""; else check_cluster true "Install into this cluster?"; fi
  choose_namespace
  check_namespace

  if $INTERACTIVE; then heading "Step 2/9 - Looking at the cluster"; else heading "Looking at the cluster"; fi
  if $CLUSTER_OK; then detect_cluster; else note "Skipped (no cluster)."; fi

  if $INTERACTIVE; then
    # B = values.yaml alone: the wizard writes only what differs from it.
    read_values "$BASE_VALUES"
    local k; B=(); for k in "${!V[@]}"; do B[$k]=${V[$k]}; done
  fi
  set_values_files
  read_values "${VALUES_FILES[@]}"
  $INTERACTIVE || validate_values

  if $INTERACTIVE; then
    run_wizard
    heading "Step 9/9 - Confirm"
    # Show the result of the answers: write them to a temporary file and read the merge back.
    make_tmp
    local tmpv="$TMP_DIR/answers.yaml"
    ( umask 077; emit_overrides >"$tmpv" )
    VALUES_FILES=("$BASE_VALUES" "$tmpv")
    VALUES_DISPLAY="values.yaml + your answers (saved as $GENERATED_VALUES)"
    read_values "${VALUES_FILES[@]}"
    validate_values
    show_summary
    preflight_checks
    prepare_charts
    live_checks
    confirm_or_exit "$($DRY_RUN && echo "Save the answers and render the manifests?" || echo "Save the answers and install now?")"
    write_generated "$GENERATED_VALUES"
    note "Re-running './install.sh -n $NAMESPACE -f $GENERATED_VALUES' reproduces this installation."
    VALUES_FILES=("$BASE_VALUES" "$GENERATED_VALUES")
    VALUES_DISPLAY=""
  else
    show_summary
    preflight_checks
    prepare_charts
    live_checks
    # A dry run changes nothing, so it needs no confirmation.
    $DRY_RUN || confirm_or_exit "Install now?"
  fi
  run_install
}

main "$@"
