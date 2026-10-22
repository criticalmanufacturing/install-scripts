#!/usr/bin/env bash
# Customer entrypoint: registry authentication, chart validation, and installation.
set +x

# Parse the complete downloaded function before starting installation.
main() {
set -Eeuo pipefail
umask 077

version=''
namespace=connectivity
release=saas-connector
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
Install the SaaS Connector using files supplied by Critical Manufacturing.

Usage: bash install.sh [options]

  --version VERSION       Install a specific release (default: latest stable)
  --values FILE           Application settings (default: ./app-values.yaml)
  --link-file FILE        Private cloud Link file (default: ./link.yaml)
  --namespace NAME        Kubernetes namespace (default: connectivity)
  --release NAME          Helm release (default: saas-connector)
  --help                  Show this help

Run in Bash on the workstation where Helm and kubectl are configured.
The script displays the target cluster and prompts for registry credentials.
Rerun with the same release and namespace to retry or upgrade an installation.
HELP
}

while (($#)); do
    case $1 in
        --version|--values|--link-file|--namespace|--release|--registry)
            if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then fail "$1 requires a value."; fi
            case $1 in
                --version) version=$2 ;;
                --values) values_file=$2 ;;
                --link-file) link_file=$2 ;;
                --namespace) namespace=$2 ;;
                --release) release=$2 ;;
                --registry) registry=$2 ;;
            esac
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
    fail 'Invalid release version; use a version such as --version 0.0.1, or omit it for latest stable.'
fi
[[ ${#namespace} -le 63 && $namespace =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    fail 'Namespace must use lowercase letters, numbers, and hyphens (maximum 63 characters).'
[[ ${#release} -le 53 && $release =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    fail 'Release must use lowercase letters, numbers, and hyphens (maximum 53 characters).'
[[ -r $values_file && -s $values_file ]] || fail "Application settings not found or empty: $values_file"
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
if ! kubectl auth can-i get secrets --namespace "$namespace" --context "$context" >/dev/null; then
    fail "Your account cannot manage this installation in namespace '$namespace'. Ask your cluster administrator for Helm installation access."
fi
can_create_namespace=false
if kubectl auth can-i create namespaces --all-namespaces --context "$context" >/dev/null; then can_create_namespace=true; fi

printf 'Cluster: %s\nNamespace: %s\nRelease: %s\nVersion: %s\n' "$context" "$namespace" "$release" "${version:-latest stable}"
printf 'Registry: %s\n' "$registry"
IFS= read -r -u 3 -p 'Install into this cluster? [y/N] ' answer
[[ $answer == y || $answer == Y ]] || fail 'Installation cancelled; no cluster changes were made.'

auth_dir=$(mktemp -d)
# Isolate Helm's Docker fallback as well as its own credential store. A seeded
# registry entry also prevents automatic native-keychain discovery.
export DOCKER_CONFIG="$auth_dir"
printf '{"auths":{"%s":{}}}\n' "$registry" >"$auth_dir/helm.json"
cp "$auth_dir/helm.json" "$auth_dir/config.json"
chart="oci://$registry/criticalmanufacturing/charts/saas-connector"
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
packages=("$auth_dir"/saas-connector-*.tgz)
if [[ ${#packages[@]} != 1 || ! -f ${packages[0]} ]]; then
    fail 'The registry download did not produce exactly one connector chart.'
fi
package=${packages[0]}
resolved_version=${package##*/}
resolved_version=${resolved_version#saas-connector-}
resolved_version=${resolved_version%.tgz}
if [[ -n $version && $version != "$resolved_version" ]]; then
    fail 'The downloaded chart does not match the requested version.'
fi
version=$resolved_version
printf 'Selected version: %s\n' "$version"
options=(--namespace "$namespace" --values "$values_file" --set-file "linkYaml=$link_file"
    --set-string "image.repository=$registry/criticalmanufacturing/saas-connector"
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

printf '\nConnector installed successfully.\n'
printf 'Ask your Critical Manufacturing contact to confirm an application request through the cloud connection.\n'
}

main "$@"
