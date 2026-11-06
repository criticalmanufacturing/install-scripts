#!/usr/bin/env bash
# Shared installer helpers.
# Initializes shared helper state and terminal formatting.
#
# Expected globals, initialized by the version entry point before calling helpers:
#   KUBECTL, HELM                       CLI commands.
#   SCRIPT_DIR, CHARTS_DIR, OUTPUT_DIR  Installer paths.
#   BASE_VALUES_FILE, GENERATED_VALUES  Base values and wizard output file paths.
#   COMPONENTS, VALUE_KEYS              Components and values keys to read.
#   OVERRIDE_KEY_ORDER                  Order for writing wizard overrides.
#   EFFECTIVE_VALUES                    Associative map of merged values.
#   BASE_VALUES                         Associative map of base values for comparison.
#   WIZARD_ANSWERS                      Associative map of plain wizard answers.
#   VALUE_OVERRIDES                     Associative map of YAML-formatted overrides.
#   VALUES_FILES, SAVED_FILES           Ordered input files and exported filenames.
#   RESIZE_PLAN                         component|statefulset|template|new-size|old-size entries.
#   CLUSTER_OK                          Cluster reachability flag.
#   DEFAULT_STORAGE_CLASS               Detected default StorageClass.
#   ACTION, NAMESPACE, USER_VALUES      Selected operation, namespace and values file.
#   DRY_RUN, INTERACTIVE                Execution and prompt flags.
#   HELM_TIMEOUT                        Helm operation timeout.

# Shared state, initialized before the entry point parses command-line options.
TMP_DIR=""              # Created lazily by make_tmp; removed by the installer's EXIT trap.
CHARTS_READY=false      # Whether selected chart dependencies have been built.
ASSUME_YES=false        # Set by parse_args when --yes is supplied.

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

# trim <string>: print the string without leading or trailing whitespace.
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# read_line <var>: read one line into a variable, trimming whitespace and a trailing CR; echo piped input.
read_line() {
  local __line=""
  if ! IFS= read -r __line; then
    [[ -n "$__line" ]] || { printf '\n'; die "No more answers on standard input. Run ./install.sh in a terminal, or use: -f <values file> --yes"; }
  fi
  __line="$(trim "${__line%$'\r'}")"
  [[ -t 0 ]] || printf '%s\n' "$__line"
  printf -v "$1" '%s' "$__line"
}

# ask <var> <question> [default]: prompt for a value; use the default for an empty answer.
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

# ask_secret <var> <question>: read a secret without echoing it; remove a trailing CR.
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

# ask_yn <var> <question> <y|n>: prompt until valid and store true or false.
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

# ask_choice <var> <question> <default> <value|description>...: select by number or value.
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

# confirm_or_exit <question>: confirm unless --yes was set; exit on cancellation or missing input.
confirm_or_exit() {
  local q=$1 answer
  if $ASSUME_YES; then return 0; fi
  if [[ ! -t 0 ]] && ! $INTERACTIVE; then
    die "Confirmation needed but standard input is not a terminal. Add --yes to proceed."
  fi
  ask_yn answer "$q" y
  $answer || { info "Cancelled. Nothing was changed."; exit 0; }
}

# kcn <kubectl args...>: run the configured Kubernetes CLI in NAMESPACE.
kcn() { "$KUBECTL" -n "$NAMESPACE" "$@"; }
# have <command>: return success when the command is available in PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# b64d: decode base64 from stdin (GNU, BSD/macOS and Git Bash accept --decode).
b64d() { base64 --decode 2>/dev/null; }

# yaml_str <string>: quote for YAML, escaping backslashes, quotes, tabs and newlines; remove CRs.
yaml_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}

# make_tmp: create TMP_DIR once for temporary installer files.
make_tmp() { [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t cmmes)"; }

# build_reader_chart: create the temporary Helm chart used to read VALUE_KEYS from merged values.
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

# read_values [--historical] <values file>...: fill EFFECTIVE_VALUES with Helm's merged values.
# Historical release values skip the current schema so older settings can be inspected during upgrades.
read_values() {
  local historical=false
  if [[ "${1:-}" == --historical ]]; then historical=true; shift; fi
  build_reader_chart
  if $historical; then
    rm -f "$TMP_DIR/values-reader/values.schema.json"
  else
    cp "$SCRIPT_DIR/values.schema.json" "$TMP_DIR/values-reader/values.schema.json"
  fi
  local -a args=()
  local f out line key value
  for f in "$@"; do args+=(-f "$f"); done
  if ! out="$("$HELM" template values-reader "$TMP_DIR/values-reader" "${args[@]}" 2>&1)"; then
    err "Could not read the values file(s): $*"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
    die "Fix the YAML syntax (indentation with spaces, 'key: value') and try again."
  fi
  EFFECTIVE_VALUES=()
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ "$line" == "# K|"* ]] || continue
    line=${line#"# K|"}
    key=${line%%|*}
    value=${line#*|}
    EFFECTIVE_VALUES["$key"]=$value
  done <<<"$out"
  # Defaults for keys that are missing from every file.
  : "${EFFECTIVE_VALUES[global.namePrefix]:=cmmes}"
  [[ -n "${EFFECTIVE_VALUES[global.namePrefix]}" ]] || EFFECTIVE_VALUES[global.namePrefix]=cmmes
  : "${EFFECTIVE_VALUES[global.tls.mode]:=auto}"; [[ -n "${EFFECTIVE_VALUES[global.tls.mode]}" ]] || EFFECTIVE_VALUES[global.tls.mode]=auto
  : "${EFFECTIVE_VALUES[global.podAntiAffinity]:=hard}"
  : "${EFFECTIVE_VALUES[global.platform]:=auto}"
  : "${EFFECTIVE_VALUES[s3.provider]:=rustfs}"; [[ -n "${EFFECTIVE_VALUES[s3.provider]}" ]] || EFFECTIVE_VALUES[s3.provider]=rustfs
  local c
  for c in "${COMPONENTS[@]}"; do
    [[ -n "${EFFECTIVE_VALUES[$c.enabled]:-}" ]] || EFFECTIVE_VALUES[$c.enabled]=true
  done
}

# check_tools <min Helm major> <min Helm minor>: verify required commands and Helm version; report optional OpenSSL.
check_tools() {
  local min_helm_major=$1 min_helm_minor=$2
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
    die "Could not determine the helm version ('$HELM version' failed). Helm ${min_helm_major}.${min_helm_minor} or newer is required."
  fi
  if (( major < min_helm_major || (major == min_helm_major && minor < min_helm_minor) )); then
    die "Helm v$ver is too old. Install Helm ${min_helm_major}.${min_helm_minor} or newer: https://helm.sh/docs/intro/install/"
  fi
  ok "helm v$ver"
}

# check_cluster <strict> [question]: check the current context; optionally confirm it and set CLUSTER_OK.
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
  ok "Cluster reachable. Context: ${C_BOLD}$ctx${C_RESET} (${server:-unknown server})"
  if [[ -n "$question" ]] && ! $ASSUME_YES && [[ -t 0 || "$INTERACTIVE" == true ]]; then
    local yes
    ask_yn yes "$question" y
    $yes || die "Switch the context first: kubectl config use-context <name>"
  fi
}

# choose_namespace: select and validate NAMESPACE from the argument, current context or prompt.
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

# require_can_i <verb> <resource>...: fail if the current user lacks any requested namespace permission.
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

# api_group_has <group> <resource>: return success when the API group exposes the resource.
api_group_has() {
  kc api-resources --api-group="$1" -o name 2>/dev/null | tr -d '\r' | grep -Eq "^$2(\.|$)"
}

# set_ov <path> <YAML value> <plain value>: record an override only when it differs from the base values in BASE_VALUES.
set_ov() {
  local base=${BASE_VALUES[$1]:-}
  [[ -z "$base" && "$3" == false ]] && base=false   # unset boolean = false
  if [[ "$base" != "$3" ]]; then VALUE_OVERRIDES["$1"]=$2; else unset 'VALUE_OVERRIDES[$1]'; fi
}

# emit_overrides: print VALUE_OVERRIDES as nested YAML in OVERRIDE_KEY_ORDER, which keeps sibling keys together.
emit_overrides() {
  local -a prev=() parts=()
  local path val i j depth ind first=true
  for path in "${OVERRIDE_KEY_ORDER[@]}"; do
    [[ -n "${VALUE_OVERRIDES[$path]+x}" ]] || continue
    val=${VALUE_OVERRIDES[$path]}
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

# ask_existing_secret <path> <label>: prompt for a Secret name, save it in WIZARD_ANSWERS and check its TLS keys.
ask_existing_secret() {
  local path=$1 label=$2 name
  while true; do
    ask name "$label" "${EFFECTIVE_VALUES[$path]:-}"
    if is_secret_name "$name"; then break; fi
    warn "Type the name of a Secret in namespace $NAMESPACE."
  done
  WIZARD_ANSWERS[$path]=$name
  check_tls_secret "$name"
}

# check_tls_secret <name>: warn if a reachable namespace lacks the Secret or its TLS keys.
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

# live_volume_size <name> <volume>: print the claim size in StatefulSet <prefix>-<name>, or empty if unavailable.
live_volume_size() {
  kcn get statefulset "${EFFECTIVE_VALUES[global.namePrefix]}-$1" \
    -o "jsonpath={.spec.volumeClaimTemplates[?(@.metadata.name==\"$2\")].spec.resources.requests.storage}" 2>/dev/null | tr -d '\r' || true
}

# ask_size <values path> <label> [<statefulset name suffix> <volume>]: prompt for a size.
# When the existing size is available, it is the default, so pressing Enter does not resize the volume.
ask_size() {
  local path=$1 label=$2 val def=${EFFECTIVE_VALUES[$1]:-} live=""
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
  WIZARD_ANSWERS[$path]=$val
}

# selected_releases: print enabled component names in install order, followed by otel when configured.
selected_releases() {
  local c
  for c in "${COMPONENTS[@]}"; do enabled "$c" && echo "$c"; done
  otel_enabled && echo otel
  true
}

# build_dependencies <component>: update the chart dependencies without refreshing repositories.
build_dependencies() {
  local comp=$1 out
  [[ -f "$CHARTS_DIR/$comp/Chart.yaml" ]] || die "Chart $CHARTS_DIR/$comp is missing. Get the complete installer package."
  if ! out="$("$HELM" dependency update --skip-refresh "$CHARTS_DIR/$comp" 2>&1)"; then
    err "helm dependency update failed for charts/$comp:"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
    exit 1
  fi
}

# ensure_ca: reuse the configured CA Secret or create a new one in NAMESPACE.
ensure_ca() {
  local name=${EFFECTIVE_VALUES[global.tls.caSecret]:-}
  [[ -n "$name" ]] || name="${EFFECTIVE_VALUES[global.namePrefix]}-ca"
  if kcn get secret "$name" >/dev/null 2>&1; then
    ok "CA Secret '$name' already exists: reused (never overwritten)"
    return 0
  fi
  have openssl || die "openssl is needed to create the CA Secret '$name'. Install it, or use global.tls.mode=existing/certManager."
  make_tmp
  local d="$TMP_DIR/ca" cn="${EFFECTIVE_VALUES[global.namePrefix]} CM MES dependencies CA"
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
  # The OpenSSL of Git for Windows writes CRLF line endings: store LF-only PEM files.
  local f
  for f in ca.crt ca.key; do
    (umask 077; tr -d '\r' <"$d/$f" >"$d/$f.lf") && mv -f "$d/$f.lf" "$d/$f"
  done
  if ! out="$(kcn create secret tls "$name" --cert "$d/ca.crt" --key "$d/ca.key" 2>&1)"; then
    err "Could not create the CA Secret '$name':"; printf '%s\n' "$out" | sed 's/^/         /' >&2; exit 1
  fi
  kcn label secret "$name" app.kubernetes.io/part-of=cm-mes-dependencies >/dev/null 2>&1 || true
  rm -f "$d/ca.key"
  ok "CA Secret '$name' created. Back it up: all certificates are signed by it."
}

# pods_ready <release>: print the number of ready pods and total pods for the Helm release.
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

# run_with_progress <release> <log> <command> [args...]: log command output and report pod readiness until it exits.
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

# diagnose <release> <log>: show Helm output and cluster hints after an installation failure.
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
    [[ "$pvc" == *"${EFFECTIVE_VALUES[global.namePrefix]}"* && "$pphase" == Pending ]] || continue
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

# prepare_charts: build dependencies once for all selected releases and set CHARTS_READY.
prepare_charts() {
  $CHARTS_READY && return 0
  local -a comps=()
  local c
  mapfile -t comps < <(selected_releases)
  for c in "${comps[@]}"; do build_dependencies "$c"; done
  ok "Charts prepared: ${comps[*]}"
  CHARTS_READY=true
}

# release_exists <release>: return success if Helm can find the release in NAMESPACE.
release_exists() { "$HELM" status "$1" -n "$NAMESPACE" >/dev/null 2>&1; }

# to_bytes <quantity>: print a size such as 50Gi, 1.5Ti or 500M in bytes; -1 if it cannot be parsed.
to_bytes() {
  awk -v q="$1" 'BEGIN {
    n = q; u = q; sub(/[A-Za-z]+$/, "", n); sub(/^[0-9.]+/, "", u)
    m["Ki"]=1024; m["Mi"]=1024^2; m["Gi"]=1024^3; m["Ti"]=1024^4; m["Pi"]=1024^5
    m["k"]=1e3; m["M"]=1e6; m["G"]=1e9; m["T"]=1e12; m["P"]=1e15; m[""]=1
    if (n == "" || !(u in m)) { print -1; exit }
    printf "%.0f\n", n * m[u] }'
}

# rendered_vcts <manifest>: print statefulset|template|size|storageClassName for each rendered claim template.
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

# check_volumes <component>: compare rendered and installed claims and add growth to RESIZE_PLAN.
# Reject forbidden changes before anything is changed.
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
    [[ -n "$psc" ]] || psc=${sc:-$DEFAULT_STORAGE_CLASS}
    exp="$(kc get storageclass "$psc" -o 'jsonpath={.allowVolumeExpansion}' 2>/dev/null | tr -d '\r' || true)"
    if [[ "$exp" != true ]]; then
      err "The '$vct' volumes of $sts cannot grow from $lsize to $size: StorageClass '${psc:-?}' does not allow"
      info "volume expansion (allowVolumeExpansion is not true, or it cannot be read). Keep $lsize. Nothing was changed."
      exit 1
    fi
    RESIZE_PLAN+=("$comp|$sts|$vct|$size|$lsize")
  done < <(rendered_vcts "$rendered")
}

# apply_resize <component>: expand planned PVCs and orphan affected StatefulSets for a subsequent Helm upgrade.
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

# safe_name <string>: replace characters outside letters, digits, dot, underscore and hyphen with underscores.
safe_name() { local s=$1; printf '%s' "${s//[^A-Za-z0-9._-]/_}"; }

# save_secret_key <secret> <key> <file>: decode a Secret key into OUTPUT_DIR and record the file.
save_secret_key() {
  local data
  data="$(kcn get secret "$1" -o "jsonpath={.data.${2//./\\.}}" 2>/dev/null || true)"
  data=${data%$'\r'}
  if [[ -z "$data" ]]; then warn "Secret $1 has no key '$2' (file $3 not saved)."; return 0; fi
  printf '%s' "$data" | b64d >"$OUTPUT_DIR/$3"
  SAVED_FILES+=("$3")
}

# parse_args [args...]: parse installer options into shared state and validate the timeout and values path.
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
      --resize-storage) ACTION=resize; shift ;;
      --uninstall)    ACTION=uninstall; shift ;;
      --timeout)      [[ $# -ge 2 ]] || die "$1 needs a value"; HELM_TIMEOUT=$2; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage >&2; die "Unknown option: $1" ;;
    esac
  done
  [[ "$HELM_TIMEOUT" =~ ^[0-9]+[smh]$|^[0-9]+m[0-9]+s$ ]] || die "--timeout must look like 20m or 1h (got '$HELM_TIMEOUT')."
  [[ -z "$USER_VALUES" || -f "$USER_VALUES" ]] || die "Values file '$USER_VALUES' not found."
}

# set_values_files: set the files passed to every release: base values, then the selected or generated file.
set_values_files() {
  VALUES_FILES=("$BASE_VALUES_FILE")
  local extra=$USER_VALUES
  if [[ -z "$extra" && -f "$GENERATED_VALUES" ]] && { [[ "$ACTION" != install ]] || $INTERACTIVE; }; then
    extra=$GENERATED_VALUES
    if $INTERACTIVE; then note "The answers in $GENERATED_VALUES are used as the defaults."
    else note "Using $GENERATED_VALUES (pass -f to use another file)."; fi
  fi
  if [[ -n "$extra" ]] && [[ "$(abs_path "$extra")" != "$(abs_path "$BASE_VALUES_FILE")" ]]; then
    VALUES_FILES+=("$extra")
  fi
}
