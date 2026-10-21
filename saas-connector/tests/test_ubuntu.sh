#!/usr/bin/env bash
# Isolated checks only: no packages, services, containers, or deployment network.
# Functions and globals below replace commands called by the sourced installer.
# shellcheck disable=SC2030,SC2031,SC2317
set -Eeuo pipefail
SCRIPT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/setup-saas-connector-ubuntu.sh
# shellcheck source=saas-connector/setup-saas-connector-ubuntu.sh
source "$SCRIPT"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
trap 'printf "FAIL: check at line %s\n" "$LINENO" >&2' ERR
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$TEST_DIR/link.yaml" <<'YAML'
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: cloud
spec:
  endpoints:
  - group: skupper-router
    name: inter-router
    host: skupper.example.com
    port: "443"
YAML

# CLI parsing and basic validation do not require Ubuntu or installation.
(
    parse_args --site-name customer-sap --link-file "$TEST_DIR/link.yaml" \
        --connector-name sap-http --app-ip 192.168.1.14 --app-port 03000
    prompt() { fail 'Complete options must not prompt'; }
    collect_inputs
    check_inputs
    [[ $NAMESPACE == default && $ROUTING_KEY == sap-http && $APP_PORT == 3000 ]]
    [[ $CLOUD_HOST == skupper.example.com ]]
)

# Site and cloud hostname defaults also work without a terminal or site option.
(
    hostname() { printf 'Ubuntu-VM\n'; }
    parse_args --link-file "$TEST_DIR/link.yaml" --connector-name sap-http \
        --app-ip 192.168.1.14 --app-port 3000 --cloud-ip 63.187.234.201
    prompt() { fail 'Default names must not prompt'; }
    collect_inputs
    check_inputs
    [[ $SITE_NAME == ubuntu-vm && $NAMESPACE == default && $CLOUD_HOST == skupper.example.com ]]
)

# The exported values used by the manual runbook survive script initialization.
SITE_NAME=asm NAMESPACE='' LINK_FILE="$TEST_DIR/link.yaml" CONNECTOR_NAME=sap2-http \
APP_IP=192.168.1.14 APP_PORT=3000 CLOUD_HOST=exported.example.com CLOUD_IP=63.187.234.201 \
bash -c '
    source "$1"
    parse_args --app-port 3001
    prompt() { die "Exported values must not prompt"; }
    collect_inputs
    check_inputs
    [[ $SITE_NAME == asm && $NAMESPACE == default && $APP_PORT == 3001 ]]
    [[ $CLOUD_HOST == exported.example.com && $CLOUD_IP == 63.187.234.201 ]]
' _ "$SCRIPT"

# Quoted endpoint hosts, CRLF, and list items starting with host are supported.
for host_value in skupper.example.com '"skupper.example.com"' "'skupper.example.com'"; do
    (
        printf 'kind: Link\r\nspec:\r\n  endpoints:\r\n  - host: %s # cloud\r\n' "$host_value" >"$TEST_DIR/quoted.yaml"
        SITE_NAME=ubuntu-vm NAMESPACE=ubuntu-vm CONNECTOR_NAME=backend APP_PORT=3000
        LINK_FILE="$TEST_DIR/quoted.yaml"
        check_inputs
        [[ $CLOUD_HOST == skupper.example.com ]]
    )
done

# Both installers infer the host when YAML keys and values are quoted.
for installer in "$SCRIPT" "${SCRIPT%.sh}-native.sh"; do
    for quote in '"' "'"; do
        printf '%sapiVersion%s: %sskupper.io/v2alpha1%s\r\n%skind%s: %sLink%s\r\n%sspec%s:\r\n  %sendpoints%s:\r\n  - %shost%s: %sskupper.example.com%s\r\n---\r\nkind: Secret\r\ndata:\r\n  host: unrelated.example.com\r\n' \
            "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" \
            "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" "$quote" \
            >"$TEST_DIR/quoted-keys.yaml"
        bash -c '
            source "$1"
            SITE_NAME=ubuntu-vm NAMESPACE=default CONNECTOR_NAME=backend APP_PORT=3000
            LINK_FILE=$2 CLOUD_HOST=""
            check_inputs
            [[ $CLOUD_HOST == skupper.example.com ]]
        ' _ "$installer" "$TEST_DIR/quoted-keys.yaml"
    done
done
(
    SITE_NAME=custom NAMESPACE=custom CONNECTOR_NAME=backend APP_PORT=3000
    LINK_FILE="$TEST_DIR/link.yaml" CLOUD_HOST=explicit.example.com
    check_inputs
    [[ $CLOUD_HOST == explicit.example.com ]]
)
if (
    LINK_FILE="$TEST_DIR/no-host.yaml"
    printf 'kind: Secret\ndata:\n  host: unrelated.example.com\n' >"$LINK_FILE"
    check_inputs
) >"$TEST_DIR/error" 2>&1; then fail 'missing Link host accepted'; fi
grep -q 'Supply --cloud-host' "$TEST_DIR/error" || fail 'missing hostname error'

for port in 0 65536 -1 x; do
    if (
        LINK_FILE="$TEST_DIR/link.yaml" SITE_NAME=customer CONNECTOR_NAME=app NAMESPACE=customer
        APP_PORT=$port
        check_inputs
    ) >"$TEST_DIR/error" 2>&1; then fail "accepted port $port"; fi
    grep -q 'Application port' "$TEST_DIR/error" || fail 'missing port error'
done
if (parse_args --app-port) >"$TEST_DIR/error" 2>&1; then fail 'accepted missing option value'; fi
if (parse_args --unknown) >"$TEST_DIR/error" 2>&1; then fail 'accepted unknown option'; fi

# Missing values are collected once; the cloud hostname needs no prompt.
(
    prompt() {
        case $1 in
            LINK_FILE) LINK_FILE="$TEST_DIR/link.yaml" ;;
            CONNECTOR_NAME) CONNECTOR_NAME=sap-http ;; APP_IP) APP_IP=192.168.1.14 ;;
            APP_PORT) APP_PORT=3000 ;; CLOUD_IP) CLOUD_IP=63.187.234.201 ;;
            *) fail "Unexpected prompt: $1" ;;
        esac
    }
    collect_inputs
    check_inputs
    [[ $CLOUD_HOST == skupper.example.com && $CLOUD_IP == 63.187.234.201 ]]
)

# A real terminal supplies answers while stdin contains the streamed script.
sed '$d' "$SCRIPT" >"$TEST_DIR/streamed.sh"
cat >>"$TEST_DIR/streamed.sh" <<'STREAM'
collect_inputs
check_inputs
printf 'RESULT:%s:%s:%s:%s\n' "$SITE_NAME" "$APP_PORT" "$NAMESPACE" "$CLOUD_HOST"
STREAM
{
    printf '%s\nbackend\n192.168.1.14\n3000\n\n' "$TEST_DIR/link.yaml"
} | script -qefc "cat '$TEST_DIR/streamed.sh' | bash -s --" /dev/null >"$TEST_DIR/prompts"
grep -q 'Path to the supplied' "$TEST_DIR/prompts" || fail 'terminal prompt was hidden'
default_site=$(hostname | tr '[:upper:]' '[:lower:]')
grep -q "RESULT:$default_site:3000:default:skupper.example.com" "$TEST_DIR/prompts" || fail 'terminal input'

# Hosts overrides preserve unrelated aliases, are repeatable, and reject conflicts.
(
    printf '127.0.0.1 localhost\n192.168.1.2 keep-alias\n' >"$TEST_DIR/hosts"
    CLOUD_HOST=skupper.example.com CLOUD_IP=63.187.234.201
    awk() {
        local arguments=("$@")
        arguments[${#arguments[@]}-1]="$TEST_DIR/hosts"
        command awk "${arguments[@]}"
    }
    sudo() { [[ $1 == tee && $2 == -a && $3 == /etc/hosts ]]; cat >>"$TEST_DIR/hosts"; }
    getent() { :; }
    configure_hosts
    configure_hosts
    [[ $(grep -c skupper.example.com "$TEST_DIR/hosts") == 1 ]]
    grep -q keep-alias "$TEST_DIR/hosts"
    if (CLOUD_IP=63.187.234.202; configure_hosts) >"$TEST_DIR/error" 2>&1; then fail 'hosts conflict accepted'; fi
    grep -q 'already uses another IP' "$TEST_DIR/error"
)

# End-to-end command flow with the host-changing commands replaced.
# Persistent input files model a failed/retried setup and an existing connector.
(
    export HOME="$TEST_DIR/home" XDG_DATA_HOME="$TEST_DIR/data"
    mkdir -p "$HOME"
    CALLS="$TEST_DIR/calls"
    STATE="$XDG_DATA_HOME/skupper/namespaces/default/input/resources"
    mkdir -p "$STATE"
    check_ubuntu() { :; }
    sudo() { printf 'sudo %s\n' "$*" >>"$CALLS"; }
    systemctl() { printf 'systemctl %s\n' "$*" >>"$CALLS"; }
    podman() { printf 'podman %s\n' "$*" >>"$CALLS"; }
    install_cli() {
        mkdir -p "$HOME/.local/bin"
        printf '#!/usr/bin/env bash\nprintf "2.2.3\\n"\n' >"$SKUPPER"
        chmod +x "$SKUPPER"
    }
    nc() { printf 'nc %s\n' "$*" >>"$CALLS"; }
    sk() {
        printf 'sk %s\n' "$*" >>"$CALLS"
        case "$1 $2" in
            'site create') touch "$STATE/Site-$3.yaml" ;;
            'connector create') touch "$STATE/Connector-$3.yaml" ;;
            'site status') printf 'NAME STATUS MESSAGE\ncustomer-sap Ready OK\n' ;;
            'link status')
                if [[ -f $STATE/Connector-sap-http.yaml ]]; then
                    printf 'NAME STATUS COST MESSAGE\ncloud Ready 1 OK\n'
                else
                    printf 'NAME STATUS COST MESSAGE\ncloud Pending 1 Connecting\n'
                fi ;;
        esac
    }
    args=(--site-name customer-sap --link-file "$TEST_DIR/link.yaml" \
          --connector-name sap-http --app-ip 192.168.1.14 --app-port 3000 --timeout 2)
    (main "${args[@]}") >"$TEST_DIR/first" 2>&1
    (main "${args[@]}" --app-port 3001) >"$TEST_DIR/second" 2>&1
    [[ $(grep -c 'sk site create' "$CALLS") == 1 ]] || fail 'site recreated on retry'
    [[ $(grep -c 'sk connector create' "$CALLS") == 1 ]] || fail 'connector recreated on retry'
    grep -q 'connector update sap-http --port 3001' "$CALLS" || fail 'connector not updated'
    grep -q 'cloud Pending' "$TEST_DIR/first" || fail 'pending link was hidden'
    grep -q 'cloud Ready' "$TEST_DIR/first" || fail 'final link status missing'
    grep -q 'systemctl --user is-active podman.socket' "$CALLS" || fail 'socket check missing'
    if grep -Eq 'system (reload|start|stop)|python|jq|openssl' "$CALLS"; then fail 'unexpected command'; fi
    [[ $(stat -c '%a' "$TEST_DIR/link.yaml") == 600 ]] || fail 'link permissions'
    nc() { return 1; }
    if (main "${args[@]}") >"$TEST_DIR/error" 2>&1; then fail 'unreachable backend accepted'; fi
    grep -q 'application TCP port is unreachable' "$TEST_DIR/error" || fail 'missing backend error'
)

# An empty status or a Pending link must never count as Ready.
for status in empty pending; do
    if (
        TIMEOUT=1 NAMESPACE=default
        sk() {
            if [[ $status == empty ]]; then printf 'There are no link resources in the namespace\n'
            else printf 'NAME STATUS COST MESSAGE\ncloud Pending 1 Connecting\n'; fi
        }
        wait_ready link
    ) >"$TEST_DIR/error" 2>&1; then fail "accepted $status link status"; fi
    grep -q 'did not reach Ready' "$TEST_DIR/error" || fail 'missing readiness error'
    grep -q 'link status after' "$TEST_DIR/error" || fail 'waiting status was hidden'
    grep -q 'default-skupper-router' "$TEST_DIR/error" || fail 'router diagnostic namespace'
done

# Optional check against the real pinned CLI: imports and updates, without Podman.
if [[ -n ${SAAS_CONNECTOR_TEST_CLI:-} ]]; then
    (
        SKUPPER=$SAAS_CONNECTOR_TEST_CLI
        [[ $("$SKUPPER" version) == 2.2.3 ]] || fail 'CLI version'
        export XDG_DATA_HOME="$TEST_DIR/real-data" XDG_CONFIG_HOME="$TEST_DIR/real-config"
        NAMESPACE=contract
        cat >"$TEST_DIR/real-link.yaml" <<'YAML'
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: cloud
spec:
  endpoints:
    - name: inter-router
      host: skupper.example.com
      port: "443"
  tlsCredentials: cloud-tls
---
apiVersion: v1
kind: Secret
metadata:
  name: cloud-tls
type: kubernetes.io/tls
data:
  ca.crt: ZmFrZQ==
  tls.crt: ZmFrZQ==
  tls.key: ZmFrZQ==
YAML
        sk site create customer-sap
        sk system apply -f "$TEST_DIR/real-link.yaml"
        sk system apply -f "$TEST_DIR/real-link.yaml"
        sk connector create backend 3000 --host 192.168.1.14 --routing-key sap-http
        sk connector update backend --port 3001 --host 192.168.1.15 --routing-key sap-http
        resources="$XDG_DATA_HOME/skupper/namespaces/contract/input/resources"
        for file in Site-customer-sap Link-cloud Secret-cloud-tls Connector-backend; do
            [[ -f $resources/$file.yaml ]] || fail "real CLI missing $file"
        done
        grep -q 'port: 3001' "$resources/Connector-backend.yaml" || fail 'real CLI port update'
        grep -q 'host: 192.168.1.15' "$resources/Connector-backend.yaml" || fail 'real CLI host update'
    ) >"$TEST_DIR/real-cli" 2>&1
fi
printf 'PASS: options, terminal prompts, setup/retry flow, failure checks%s\n' "${SAAS_CONNECTOR_TEST_CLI:+, real CLI imports and updates}"
