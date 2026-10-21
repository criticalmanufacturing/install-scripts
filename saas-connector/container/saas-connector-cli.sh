#!/usr/bin/env bash
# Use the pod namespace, and query the running router for plain link status.
set -euo pipefail
original=("$@")
namespace=${NAMESPACE:-default}
platform=${SKUPPER_PLATFORM:-linux}
platform_flag=''
valid_flags=1
words=()
while (($#)); do
    case $1 in
        --namespace|-n)
            (($# >= 2)) || { valid_flags=0; break; }
            namespace=$2; shift 2 ;;
        --namespace=*|-n=*) namespace=${1#*=}; shift ;;
        -n?*) namespace=${1:2}; shift ;;
        --platform|-p)
            (($# >= 2)) || { valid_flags=0; break; }
            platform=${platform_flag:-$2}; platform_flag=$platform; shift 2 ;;
        --platform=*|-p=*)
            platform=${platform_flag:-${1#*=}}; platform_flag=$platform; shift ;;
        *) words+=("$1"); shift ;;
    esac
done

if [[ $valid_flags == 1 && $platform == linux && ${#words[@]} == 2 && ${words[0]} == link && ${words[1]} == status \
      && ${#namespace} -le 63 && $namespace =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    runtime="/output/namespaces/$namespace/runtime"
    access="$runtime/resources/RouterAccess-skupper-local.yaml"
    if [[ ! -r $access ]]; then
        printf 'No router configuration for namespace %s.\n' "$namespace" >&2
        exit 1
    fi
    port=$(awk '$1=="port:" { print $2; exit }' "$access")
    [[ $port =~ ^[0-9]+$ ]] || { printf 'Cannot read the local router management port.\n' >&2; exit 1; }
    certs="$runtime/certs/skupper-local-client"
    # skmanage is supplied by the official router image; TLS verification stays enabled.
    exec skmanage query --type connector \
        name host port role cost connectionStatus connectionMsg \
        --bus "amqps://127.0.0.1:$port" --timeout 5 \
        --ssl-certificate "$certs/tls.crt" --ssl-key "$certs/tls.key" \
        --ssl-trustfile "$certs/ca.crt" --sasl-mechanisms EXTERNAL
fi

# Other commands and output formats keep the upstream CLI behavior.
exec /usr/local/bin/skupper-cli --namespace "${NAMESPACE:-default}" "${original[@]}"
