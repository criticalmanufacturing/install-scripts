#!/usr/bin/env bash
# Customer entrypoint: installation choice, verified downloads, and setup.
set +x

# Parse the complete downloaded function before starting installation.
main() {
set -Eeuo pipefail
umask 077

version=''
mode=''
ubuntu_options=()
namespace_supplied=false
release_supplied=false
values_supplied=false
link_supplied=false
namespace=default
release=cm-cloud-bridge
values_file=./app-values.yaml
link_file=./link.yaml
registry=criticalmanufacturing.io
pull_secret=criticalmanufacturing-registry
auth_dir=''
stage='checking the supplied files and cluster access'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# ShellCheck does not follow this function's EXIT-trap invocation.
# shellcheck disable=SC2317
cleanup() {
    if [[ -n $auth_dir ]]; then rm -rf -- "$auth_dir"; fi
    unset registry_token registry_auth
}
trap 'cleanup' EXIT
trap 'printf "Installation stopped while %s. Contact Critical Manufacturing with this error.\n" "$stage" >&2' ERR

usage() {
    cat <<'HELP'
Install the CM Cloud Bridge using files supplied by Critical Manufacturing.

Usage: bash install.sh [options]

  --mode MODE             native, podman, or helm (default: ask in the terminal)
  --version VERSION       Pin a release (default: latest stable)
  --values FILE           Optional application settings (default: ./app-values.yaml)
  --link-file FILE        Private cloud Link file (default: ./link.yaml)
  --namespace NAME        Installation namespace (default: default)
  --release NAME          Helm release (default: cm-cloud-bridge)
  --help                  Show this help

Ubuntu options:
  --connector-name NAME   Connector name supplied by Critical Manufacturing
  --app-ip ADDRESS        Application address reachable from this machine
  --app-port PORT         Application TCP port
  --site-name NAME        Retain an existing Ubuntu site identity
  --routing-key KEY       Optional routing key override
  --cloud-host HOST       Optional cloud hostname override
  --cloud-ip IP           Optional cloud ingress IP override
  --timeout SECONDS       Readiness timeout

Native and Podman run directly on Ubuntu 24.04/26.04 as a normal user with sudo.
Helm requires Helm and kubectl configured for an existing cluster.
An existing settings file is used; otherwise the minimum application settings
are requested interactively.
Keep the same site/namespace or Helm release/namespace when retrying or upgrading.
HELP
}

while (($#)); do
    case $1 in
        --mode|--version|--values|--link-file|--namespace|--release|--registry)
            if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then fail "$1 requires a value."; fi
            case $1 in
                --mode) mode=$2 ;;
                --version) version=$2 ;;
                --values) values_file=$2; values_supplied=true ;;
                --link-file) link_file=$2; link_supplied=true ;;
                --namespace) namespace=$2; namespace_supplied=true ;;
                --release) release=$2; release_supplied=true ;;
                --registry) registry=$2 ;;
            esac
            shift 2 ;;
        --connector-name|--app-ip|--app-port|--site-name|--routing-key|--cloud-host|--cloud-ip|--timeout)
            if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then fail "$1 requires a value."; fi
            ubuntu_options+=("$1" "$2")
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1. Run with --help for usage." ;;
    esac
done

if [[ ! $registry =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$ ]]; then
    fail 'Registry must be a lowercase hostname with an optional port, without a scheme, path, or credentials.'
fi
# Container runtimes treat a bare name as an image namespace on their default registry.
[[ $registry == *.* || $registry == *:* || $registry == localhost ]] ||
    fail 'Registry must be a fully qualified hostname, localhost, or a hostname with an explicit port.'
registry_host=${registry%%:*}
[[ ${#registry_host} -le 253 ]] || fail 'Registry hostname is too long.'
IFS=. read -r -a registry_labels <<<"$registry_host"
for label in "${registry_labels[@]}"; do
    [[ ${#label} -le 63 ]] || fail 'Registry hostname label is too long.'
done
if [[ $registry == *:* ]]; then
    registry_port=${registry##*:}
    ((10#$registry_port >= 1 && 10#$registry_port <= 65535)) || fail 'Registry port must be 1..65535.'
fi
if [[ -n $version && ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    fail 'Invalid release version; use a version such as --version 1.0.1, or omit it for latest stable.'
fi
if [[ -z $mode ]]; then
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        fail 'An interactive terminal is required to choose an installation. Use --mode native, podman, or helm.'
    fi
    printf 'Choose how to install the CM Cloud Bridge:\n'
    printf '  1) Native on Ubuntu\n  2) Podman on Ubuntu\n  3) Helm on Kubernetes/OpenShift\n'
    IFS= read -r -u 3 -p 'Installation method [1/2/3, q to cancel]: ' selection || fail 'No installation method received.'
    case $selection in
        1|native) mode=native ;;
        2|podman) mode=podman ;;
        3|helm) mode=helm ;;
        q|Q) fail 'Installation cancelled; no changes were made.' ;;
        *) fail 'Choose native, podman, or helm (1, 2, or 3).' ;;
    esac
    exec 3>&-
fi
case $mode in
    native|podman|helm) ;;
    *) fail 'Installation mode must be native, podman, or helm.' ;;
esac

install_ubuntu() {
    [[ $release_supplied == false ]] || fail '--release applies to Helm. Use --site-name for Ubuntu.'
    [[ -z $version || $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
        fail 'Ubuntu release versions must use X.Y.Z, such as --version 1.0.1.'
    local tool installer base checksum_file checksum extra expected_sum='' line key value stable_version seen=' '
    local settings_options=()
    for tool in curl mktemp sha256sum; do
        command -v "$tool" >/dev/null || fail "Install $tool before running this installer."
    done
    if [[ $values_supplied == true || -f $values_file ]]; then
        [[ -r $values_file && -s $values_file ]] || fail "Application settings not found or empty: $values_file"
        # CM supplies simple top-level scalars. Reject YAML escaping rather than
        # interpreting it differently from the cluster installer.
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            if [[ $line =~ ^(connectorName|appIp|appPort):[[:space:]]*(.*)$ ]]; then
                key=${BASH_REMATCH[1]}
                value=${BASH_REMATCH[2]}
                [[ $seen != *" $key "* ]] || fail "Application settings repeat $key."
                seen+="$key "
                value=${value%"${value##*[![:space:]]}"}
                case $value in
                    \"*\") value=${value:1:${#value}-2}; [[ $value != *[\\\"]* ]] || fail "Unsupported quoting for $key; ask Critical Manufacturing for simple settings." ;;
                    \'*\') value=${value:1:${#value}-2}; [[ $value != *\'* ]] || fail "Unsupported quoting for $key; ask Critical Manufacturing for simple settings." ;;
                    *) [[ $value != *[[:space:]\\\"\'\#\[\]\{\}\&\*\!\|\>]* ]] || fail "Unsupported value for $key; ask Critical Manufacturing for simple settings." ;;
                esac
                [[ -n $value ]] || fail "Application setting $key is empty."
                case $key in
                    connectorName) settings_options+=(--connector-name "$value") ;;
                    appIp) settings_options+=(--app-ip "$value") ;;
                    appPort) settings_options+=(--app-port "$value") ;;
                esac
            fi
        done <"$values_file"
        [[ $seen == *' connectorName '* && $seen == *' appIp '* && $seen == *' appPort '* ]] ||
            fail 'Application settings need connectorName, appIp, and appPort for Ubuntu installation.'
    fi
    if [[ $link_supplied == true || -f $link_file ]]; then
        [[ -r $link_file && -s $link_file ]] || fail "Cloud Link file not found or empty: $link_file"
        settings_options+=(--link-file "$link_file")
    fi
    if [[ $namespace_supplied == true ]]; then settings_options+=(--namespace "$namespace"); fi
    if [[ -z $version ]]; then
        stage='resolving the latest stable Ubuntu release'
        # Promote this public catalog only after all release artifacts pass verification.
        if ! stable_version=$(curl --disable --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' --max-redirs 5 \
            --connect-timeout 15 --max-time 60 \
            https://raw.githubusercontent.com/criticalmanufacturing/install-scripts/main/cm-cloud-bridge/stable-version); then
            fail 'Could not resolve the latest stable Ubuntu release. Check download access or use --version X.Y.Z supplied by Critical Manufacturing.'
        fi
        if [[ $stable_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
            version=$stable_version
        else
            fail 'The stable Ubuntu release catalog contains an invalid version. Contact Critical Manufacturing or use a supplied --version X.Y.Z.'
        fi
    fi
    installer=setup-cm-cloud-bridge-ubuntu.sh
    if [[ $mode == native ]]; then installer=setup-cm-cloud-bridge-ubuntu-native.sh; fi
    base="https://$registry/repository/tools/cm-cloud-bridge-$version/latest"
    auth_dir=$(mktemp -d)
    stage='downloading and verifying the Ubuntu installer'
    printf 'Installation: %s\nSelected version: %s\n' "$mode" "$version"
    for checksum_file in VERSION SHA256SUMS "$installer"; do
        curl --disable --fail --silent --show-error --location \
            --connect-timeout 30 --max-time 120 --output "$auth_dir/$checksum_file" "$base/$checksum_file"
    done
    [[ $(cat "$auth_dir/VERSION") == "$version" ]] || fail 'The downloaded Ubuntu release version does not match the requested version.'
    while read -r checksum checksum_file extra; do
        if [[ $checksum_file == "$installer" || $checksum_file == "./$installer" ]]; then
            [[ -z $expected_sum && -z $extra && $checksum =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid or repeated installer checksum.'
            expected_sum=$checksum
        fi
    done <"$auth_dir/SHA256SUMS"
    [[ -n $expected_sum ]] || fail 'The release checksum manifest does not contain the selected installer.'
    (cd "$auth_dir" && printf '%s  %s\n' "$expected_sum" "$installer" | sha256sum --check --status) ||
        fail 'The Ubuntu installer download failed checksum verification.'
    bash -n "$auth_dir/$installer" || fail 'The downloaded Ubuntu installer is incomplete or invalid.'
    stage='running the Ubuntu installer'
    # Defaults from the supplied file precede explicit overrides.
    bash "$auth_dir/$installer" "${settings_options[@]}" "${ubuntu_options[@]}"
}

if [[ $mode != helm ]]; then
    install_ubuntu
    return
fi
[[ ${#ubuntu_options[@]} == 0 ]] || fail 'Ubuntu installation options require --mode native or --mode podman.'

[[ ${#namespace} -le 63 && $namespace =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    fail 'Namespace must use lowercase letters, numbers, and hyphens (maximum 63 characters).'
[[ ${#release} -le 53 && $release =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    fail 'Release must use lowercase letters, numbers, and hyphens (maximum 53 characters).'
values_present=false
if [[ -e $values_file || -L $values_file ]]; then
    [[ -f $values_file && -r $values_file && -s $values_file ]] || fail "Application settings not found or empty: $values_file"
    values_present=true
fi
[[ -r $link_file && -s $link_file ]] || fail "Cloud Link file not found or empty: $link_file"
for tool in helm kubectl base64 mktemp grep; do
    command -v "$tool" >/dev/null || fail "Install $tool before running this installer."
done
helm_version=$(helm version --short)
if [[ $helm_version =~ ^v([0-9]+)\.([0-9]+)\. ]]; then
    ((BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 8))) ||
        fail 'Helm 3.8 or newer is required.'
else
    fail 'Could not determine the Helm version.'
fi
# Use the terminal explicitly: stdin contains the script when invoked with curl | bash.
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    fail 'An interactive terminal is required. Run this command from a terminal window.'
fi
context=$(kubectl config current-context)
[[ -n $context ]] || fail 'Configure kubectl for your cluster before continuing.'
if [[ $namespace_supplied == false ]]; then
    while :; do
        IFS= read -r -u 3 -p 'Kubernetes namespace [default]: ' namespace || fail 'No Kubernetes namespace received.'
        namespace=${namespace:-default}
        if [[ ${#namespace} -le 63 && $namespace =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then break; fi
        printf 'Use 1..63 lowercase letters, numbers, or hyphens, starting and ending with a letter or number.\n' >&2
    done
fi
if ! kubectl auth can-i get secrets --namespace "$namespace" --context "$context" >/dev/null; then
    fail "Your account cannot manage this installation in namespace '$namespace'. Ask your cluster administrator for Helm installation access."
fi
can_create_namespace=false
if kubectl auth can-i create namespaces --all-namespaces --context "$context" >/dev/null; then can_create_namespace=true; fi

auth_dir=$(mktemp -d)
if [[ $values_present == false ]]; then
    while :; do
        IFS= read -r -u 3 -p 'Connector name (routing key): ' connector_name || fail 'No connector name received.'
        if [[ ${#connector_name} -le 63 && $connector_name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then break; fi
        printf 'Use 1..63 lowercase letters, numbers, or hyphens, starting and ending with a letter or number.\n' >&2
    done
    while :; do
        IFS= read -r -u 3 -p 'Application address: ' application_address || fail 'No application address received.'
        if [[ $application_address =~ ^[A-Za-z0-9_:][A-Za-z0-9_.:%-]*$ ]]; then break; fi
        printf 'Enter the application IP address or hostname without spaces or a URL scheme.\n' >&2
    done
    while :; do
        IFS= read -r -u 3 -p 'Application TCP port: ' application_port || fail 'No application port received.'
        if [[ $application_port =~ ^[0-9]+$ && ${#application_port} -le 5 ]] &&
            ((10#$application_port >= 1 && 10#$application_port <= 65535)); then break; fi
        printf 'Enter a TCP port from 1 to 65535.\n' >&2
    done
    # Validated scalars cannot inject YAML; retain these settings only for this run.
    values_file="$auth_dir/app-values.yaml"
    printf 'connectorName: "%s"\nappIp: "%s"\nappPort: %s\n' \
        "$connector_name" "$application_address" "$((10#$application_port))" >"$values_file"
fi

printf 'Cluster: %s\nNamespace: %s\nRelease: %s\nVersion: %s\n' "$context" "$namespace" "$release" "${version:-latest stable}"
printf 'Registry: %s\n' "$registry"
IFS= read -r -u 3 -p 'Install into this cluster? [y/N] ' answer
[[ $answer == y || $answer == Y ]] || fail 'Installation cancelled; no cluster changes were made.'

# Isolate Helm's Docker fallback as well as its own credential store. A seeded
# registry entry also prevents automatic native-keychain discovery.
export DOCKER_CONFIG="$auth_dir"
printf '{"auths":{"%s":{}}}\n' "$registry" >"$auth_dir/helm.json"
cp "$auth_dir/helm.json" "$auth_dir/config.json"
chart="oci://$registry/criticalmanufacturing/charts/cm-cloud-bridge"
pull_command=(helm pull "$chart")
if [[ -n $version ]]; then pull_command+=(--version "$version"); fi
authenticated=false
downloaded=false
if [[ $registry != criticalmanufacturing.io ]]; then
    stage='checking anonymous access to the selected registry'
    if "${pull_command[@]}" --registry-config "$auth_dir/helm.json" --destination "$auth_dir" >"$auth_dir/pull.log" 2>&1; then
        downloaded=true
    else
        printf 'Anonymous download unavailable; enter registry credentials to retry.\n'
    fi
fi
if [[ $downloaded == false ]]; then
    stage='authenticating with the selected registry'
    IFS= read -r -u 3 -p 'Registry username: ' registry_user
    IFS= read -r -s -u 3 -p 'Registry token: ' registry_token
    printf '\n' >&3
    [[ -n $registry_user && -n $registry_token ]] || fail 'Registry username and token are required.'
    registry_auth=$(printf '%s:%s' "$registry_user" "$registry_token" | base64 | tr -d '\n')
    printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$registry" \
        "$registry_auth" >"$auth_dir/docker.json"
    cp "$auth_dir/docker.json" "$auth_dir/helm.json"
    cp "$auth_dir/docker.json" "$auth_dir/config.json"
    printf '%s' "$registry_token" | helm registry login "$registry" \
        --username "$registry_user" --password-stdin --registry-config "$auth_dir/helm.json"
    unset registry_token registry_auth
    stage='downloading the chart from the selected registry'
    "${pull_command[@]}" --registry-config "$auth_dir/helm.json" --destination "$auth_dir"
    authenticated=true
fi
stage='validating the supplied chart settings'
# Helm resolves the latest stable release when no version is specified. Reuse the
# downloaded package so a newer publication cannot change this installation.
packages=("$auth_dir"/cm-cloud-bridge-*.tgz)
if [[ ${#packages[@]} != 1 || ! -f ${packages[0]} ]]; then
    fail 'The registry download did not produce exactly one connector chart.'
fi
package=${packages[0]}
resolved_version=${package##*/}
resolved_version=${resolved_version#cm-cloud-bridge-}
resolved_version=${resolved_version%.tgz}
if [[ -n $version && $version != "$resolved_version" ]]; then
    fail 'The downloaded chart does not match the requested version.'
fi
version=$resolved_version
printf 'Selected version: %s\n' "$version"
options=(--namespace "$namespace" --values "$values_file" --set-file "linkYaml=$link_file"
    --set-string "image.repository=$registry/criticalmanufacturing/cm-cloud-bridge"
    --set-string "image.tag=$version")
if [[ $authenticated == true ]]; then
    options+=(--set "imagePullSecrets[0].name=$pull_secret")
else
    # A values file represents an empty list on every supported Helm version.
    printf 'imagePullSecrets: []\n' >"$auth_dir/pull-values.yaml"
    options+=(--values "$auth_dir/pull-values.yaml")
fi
# Discard rendered manifests: they contain the private Link credentials.
printf 'Validating the application settings...\n'
helm template "$release" "$package" "${options[@]}" >/dev/null

stage='preparing the installation namespace and image access'
printf 'Preparing namespace %s and image access...\n' "$namespace"
if [[ $can_create_namespace == true ]]; then
    if ! kubectl create namespace "$namespace" --context "$context" >"$auth_dir/namespace.log" 2>&1; then
        if ! grep -q AlreadyExists "$auth_dir/namespace.log"; then
            cat "$auth_dir/namespace.log" >&2
            fail "Cannot prepare namespace '$namespace'. Ask your cluster administrator to create it."
        fi
    fi
fi
if [[ $authenticated == true ]]; then
    kubectl create secret generic "$pull_secret" --namespace "$namespace" \
        --type=kubernetes.io/dockerconfigjson --from-file=".dockerconfigjson=$auth_dir/docker.json" \
        --dry-run=client -o yaml --context "$context" | kubectl apply -f - --context "$context"
fi

stage='starting the connector (this can take up to five minutes)'
printf 'Installing the connector and waiting for readiness (up to five minutes)...\n'
printf 'Readiness requires the connector to reach the configured application.\n'
printf 'To check progress from another terminal:\n  '
printf '%q ' kubectl get pods --namespace "$namespace" --context "$context" --selector "app.kubernetes.io/instance=$release"
printf '\n'
helm upgrade --install "$release" "$package" "${options[@]}" --kube-context "$context" --wait --timeout 5m \
    >"$auth_dir/install.log"

printf '\nCM Cloud Bridge installed successfully.\n'
printf 'Ask your Critical Manufacturing contact to confirm an application request through the cloud connection.\n'
}

run_logged() {
    local argument log_file status
    local -a pipeline_status
    for argument in "$@"; do
        if [[ $argument == --help || $argument == -h ]]; then
            main "$@"
            return
        fi
    done
    if ! command -v mktemp >/dev/null || ! command -v tee >/dev/null; then
        printf 'Installation logging is unavailable; continuing with terminal output.\n' >&2
        main "$@"
        return
    fi
    log_file=$(umask 077; mktemp "$PWD/cm-cloud-bridge-install-XXXXXX.log" 2>/dev/null) ||
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/cm-cloud-bridge-install-XXXXXX.log" 2>/dev/null) || {
            printf 'Cannot create an installation log; continuing with terminal output.\n' >&2
            main "$@"
            return
        }
    # Keep main's error handling and credential cleanup in its pipeline child.
    # Waiting for tee also ensures the log is complete before displaying its path.
    set +e
    main "$@" 2>&1 | tee -- "$log_file"
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if [[ ${pipeline_status[1]} != 0 ]]; then
        printf 'The installation log could not capture all output.\n' >&2
        if [[ $status == 0 ]]; then status=${pipeline_status[1]}; fi
    fi
    printf '\nInstaller exit status: %s\n' "$status" >>"$log_file" ||
        printf 'The installation log could not record the final status.\n' >&2
    printf '\nInstallation log: %s\n' "$log_file"
    return "$status"
}

run_logged "$@"
