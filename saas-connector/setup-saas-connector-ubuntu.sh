#!/usr/bin/env bash
# Follow the Ubuntu VM runbook using Bash and Ubuntu command-line utilities.
# Run as the normal VM login user, without sudo bash.
set -Eeuo pipefail
set +x
umask 077

readonly SKUPPER_VERSION=2.2.3
SITE_NAME=${SITE_NAME:-} NAMESPACE=${NAMESPACE:-} LINK_FILE=${LINK_FILE:-}
CONNECTOR_NAME=${CONNECTOR_NAME:-} ROUTING_KEY=${ROUTING_KEY:-}
APP_IP=${APP_IP:-} APP_PORT=${APP_PORT:-} CLOUD_HOST=${CLOUD_HOST:-} CLOUD_IP=${CLOUD_IP:-}
TIMEOUT=${TIMEOUT:-180} WORK_DIR='' STAGE='options'

log() { printf '\n[%s] %s\n' "$STAGE" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
cleanup() { if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }

usage() {
    cat <<'HELP'
Usage: bash setup-saas-connector-ubuntu.sh [options]
   or: curl -fsSL SCRIPT_URL | bash -s -- [options]

Missing required values are requested in the terminal:
  --link-file PATH       Local Link YAML supplied by the cloud administrator
  --connector-name NAME  Name matching the cloud Listener's routing key
  --app-ip ADDRESS      Application address reachable from this VM
  --app-port PORT        Application TCP port (1..65535)

Optional:
  --site-name NAME       Defaults to this machine's hostname in lowercase
  --cloud-host HOST      Defaults to the first endpoint host in the Link YAML
  --cloud-ip IP          Ingress IP for that hostname; blank means existing DNS
  --routing-key KEY      Defaults to the connector name
  --namespace NAME       Defaults to default, like the manual Skupper commands
  --timeout SECONDS      Time to wait for Site/Link readiness (default: 180)
  -h, --help             Show this help

Run as a normal Ubuntu 24.04/26.04 user with sudo access. No Python is used.
Exported setup variables are accepted; command-line options take precedence.
HELP
}

parse_args() {
    while (($#)); do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --site-name|--namespace|--link-file|--connector-name|--routing-key|--app-ip|--app-port|--cloud-host|--cloud-ip|--timeout)
                if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then die "Missing value for $1."; fi
                case $1 in
                    --site-name) SITE_NAME=$2 ;; --namespace) NAMESPACE=$2 ;;
                    --link-file) LINK_FILE=$2 ;; --connector-name) CONNECTOR_NAME=$2 ;;
                    --routing-key) ROUTING_KEY=$2 ;; --app-ip) APP_IP=$2 ;;
                    --app-port) APP_PORT=$2 ;; --cloud-host) CLOUD_HOST=$2 ;;
                    --cloud-ip) CLOUD_IP=$2 ;; --timeout) TIMEOUT=$2 ;;
                esac
                shift 2 ;;
            *) die "Unknown option: $1. Use --help." ;;
        esac
    done
}

prompt() {
    local variable=$1 message=$2
    # Read the terminal, not the script stream, so curl | bash works too.
    { exec 3<>/dev/tty; } 2>/dev/null || die "Cannot read $variable. Run in a terminal or supply its command-line option (see --help)."
    IFS= read -r -u 3 -p "$message: " "${variable?}" || die "No answer received for $variable."
    exec 3>&-
}

collect_inputs() {
    local interactive=0 variable
    for variable in LINK_FILE CONNECTOR_NAME APP_IP APP_PORT; do
        if [[ -z ${!variable} ]]; then interactive=1; fi
    done
    SITE_NAME=${SITE_NAME:-$(hostname | tr '[:upper:]' '[:lower:]')}
    while [[ -z $LINK_FILE ]]; do prompt LINK_FILE 'Path to the supplied link.yaml'; done
    while [[ -z $CONNECTOR_NAME ]]; do prompt CONNECTOR_NAME 'Connector name (cloud Listener routing key)'; done
    while [[ -z $APP_IP ]]; do prompt APP_IP 'Application IP address'; done
    while [[ -z $APP_PORT ]]; do prompt APP_PORT 'Application TCP port'; done
    if ((interactive)) && [[ -z $CLOUD_IP ]]; then
        prompt CLOUD_IP 'Cloud ingress IP override (Enter to use existing DNS)'
    fi
    # Accept a literal ~/ copied into the path prompt.
    LINK_FILE=${LINK_FILE/#\~\//$HOME/}
    NAMESPACE=${NAMESPACE:-default}
    ROUTING_KEY=${ROUTING_KEY:-$CONNECTOR_NAME}
}

check_inputs() {
    [[ -f $LINK_FILE && -r $LINK_FILE ]] || die "Link file is not readable: $LINK_FILE"
    if [[ -z $CLOUD_HOST ]]; then
        # Read the generated Link format; leave YAML import/validation to Skupper.
        CLOUD_HOST=$(awk '
            { sub(/\r$/, ""); gsub(/["\047]/, "") }
            /^---([[:space:]]|$)/ { link=0 }
            $1=="kind:" { link=($2=="Link") }
            link && ($1=="host:" || ($1=="-" && $2=="host:")) {
                host=($1=="host:" ? $2 : $3)
                print host; exit
            }
        ' "$LINK_FILE")
        [[ -n $CLOUD_HOST ]] || die 'Cannot read an endpoint hostname from the Link YAML. Supply --cloud-host explicitly.'
    fi
    if [[ ! $APP_PORT =~ ^[0-9]{1,5}$ ]] || ((10#$APP_PORT < 1 || 10#$APP_PORT > 65535)); then die 'Application port must be 1..65535.'; fi
    APP_PORT=$((10#$APP_PORT))
    if [[ ! $TIMEOUT =~ ^[0-9]{1,4}$ ]] || ((10#$TIMEOUT < 1 || 10#$TIMEOUT > 3600)); then die 'Timeout must be 1..3600 seconds.'; fi
    TIMEOUT=$((10#$TIMEOUT))
    local name
    for name in "$SITE_NAME" "$NAMESPACE" "$CONNECTOR_NAME"; do
        [[ ${#name} -le 63 && $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Use lowercase letters, digits and hyphens for names (max 63): $name"
    done
    if [[ -n $CLOUD_IP ]]; then
        [[ $CLOUD_HOST =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die 'Invalid cloud hostname.'
        [[ $CLOUD_IP =~ ^[0-9a-fA-F:.]+$ ]] || die 'Invalid cloud IP address.'
    fi
}

check_ubuntu() (
    local ID='' VERSION_ID=''
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == ubuntu && ( $VERSION_ID == 24.04 || $VERSION_ID == 26.04 ) ]] || die 'Use Ubuntu 24.04 or 26.04 LTS.'
)

install_cli() {
    local arch checksum
    case $(uname -m) in
        x86_64) arch=amd64; checksum=9eb77dab5f2659becaca53364a38df38746b1850788d2652ef2084fcc3b325ab ;;
        aarch64|arm64) arch=arm64; checksum=447de7721bd1f6f54c918c951dff5e7d3c660660dea7848cf269bb9cf0df6fa1 ;;
        *) die 'Supported architectures: amd64 and arm64.' ;;
    esac
    if [[ -x $SKUPPER ]]; then
        [[ $("$SKUPPER" version) == "$SKUPPER_VERSION" ]] || die "Existing $SKUPPER must be version $SKUPPER_VERSION."
        return
    fi
    curl -fL --retry 3 -o "$WORK_DIR/skupper.tgz" \
        "https://github.com/skupperproject/skupper/releases/download/$SKUPPER_VERSION/skupper-cli-$SKUPPER_VERSION-linux-$arch.tgz"
    printf '%s  %s\n' "$checksum" "$WORK_DIR/skupper.tgz" | sha256sum --check --status || die 'Skupper download checksum failed.'
    tar -xzf "$WORK_DIR/skupper.tgz" -C "$WORK_DIR" skupper
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$WORK_DIR/skupper" "$SKUPPER"
}

sk() { "$SKUPPER" --platform podman --namespace "$NAMESPACE" "$@"; }

configure_hosts() {
    [[ -n $CLOUD_IP ]] || return 0
    local existing
    existing=$(awk -v host="$CLOUD_HOST" '
        { sub(/#.*/, ""); for (i=2; i<=NF; i++) if (tolower($i)==tolower(host)) print $1 }
    ' /etc/hosts | sort -u)
    if [[ -n $existing ]]; then
        [[ $existing == "$CLOUD_IP" ]] || die "An /etc/hosts entry for $CLOUD_HOST already uses another IP. Correct it to $CLOUD_IP and rerun."
        log "Existing /etc/hosts mapping matches: $CLOUD_IP $CLOUD_HOST"
    else
        printf '%s %s\n' "$CLOUD_IP" "$CLOUD_HOST" | sudo tee -a /etc/hosts >/dev/null
    fi
    getent hosts "$CLOUD_HOST"
}

wait_ready() {
    local kind=$1 output previous='' start=$SECONDS next_report=$SECONDS
    log "Waiting up to ${TIMEOUT}s for $kind in namespace $NAMESPACE to become Ready."
    while ((SECONDS - start < TIMEOUT)); do
        # Skupper 2.2.3 status tables use NAME STATUS ...; check every resource.
        if output=$(sk "$kind" status 2>&1) && printf '%s\n' "$output" | awk '
            $1=="NAME" { table=1; next }
            table && NF { count++; if ($2!="Ready") pending=1 }
            END { exit !(count>0 && !pending) }
        '; then
            printf '%s\n' "$output"
            return
        fi
        if [[ $output != "$previous" ]] || ((SECONDS >= next_report)); then
            log "$kind status after $((SECONDS - start))s:"
            printf '%s\n' "$output"
            previous=$output
            next_report=$((SECONDS + 10))
        fi
        sleep 2
    done
    log "Router logs: podman logs --tail 50 $NAMESPACE-skupper-router"
    die "$kind did not reach Ready within ${TIMEOUT}s. Check cloud reachability and: journalctl --user -u skupper-controller.service -n 50"
}

main() {
    trap cleanup EXIT
    # Do not print the failed command: link commands may handle credentials.
    trap 'die "Step failed at line $LINENO. Fix the reported error and rerun with the same site name and namespace."' ERR
    parse_args "$@"
    STAGE='1. Ubuntu and setup values'
    check_ubuntu
    [[ $EUID -ne 0 ]] || die 'Run as the normal VM login user, without sudo bash.'
    collect_inputs
    check_inputs
    export SKUPPER_PLATFORM=podman SKUPPER_SYSTEM_RELOAD_TYPE=auto
    SKUPPER="$HOME/.local/bin/skupper"
    local resources="${XDG_DATA_HOME:-$HOME/.local/share}/skupper/namespaces/$NAMESPACE/input/resources"
    log "Site: $SITE_NAME | Namespace: $NAMESPACE | Connector: $CONNECTOR_NAME | Application: $APP_IP:$APP_PORT"
    log "Cloud: $CLOUD_HOST | IP override: ${CLOUD_IP:-none (existing DNS)}"

    STAGE='2. Ubuntu prerequisites and rootless Podman'
    sudo -v
    sudo apt-get update
    sudo apt-get install -y curl ca-certificates tar podman uidmap dbus-user-session netcat-openbsd
    systemctl --user enable --now podman.socket
    systemctl --user is-active podman.socket
    sudo loginctl enable-linger "$(id -un)"
    systemctl --user enable podman-restart.service
    podman --version

    STAGE='3. Skupper CLI'
    WORK_DIR=$(mktemp -d)
    install_cli
    export PATH="$HOME/.local/bin:$PATH"
    "$SKUPPER" version

    STAGE='4. Cloud hostname mapping'
    configure_hosts
    # This must happen before site creation: Podman copies hosts into new containers.
    STAGE='5. Skupper site'
    sk system install --reload-type auto
    systemctl --user enable --now skupper-controller.service
    if [[ ! -f $resources/Site-$SITE_NAME.yaml ]]; then
        sk site create "$SITE_NAME"
    fi
    wait_ready site

    STAGE='6. Import cloud link'
    chmod 600 "$LINK_FILE"
    sk system apply -f "$LINK_FILE"
    # The auto controller may still be processing the link; finish local setup.
    sk link status || true

    STAGE='7. Application connector'
    nc -z -w 5 "$APP_IP" "$APP_PORT" || die 'The application TCP port is unreachable from this VM.'
    if [[ -f $resources/Connector-$CONNECTOR_NAME.yaml ]]; then
        sk connector update "$CONNECTOR_NAME" --port "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY"
    else
        sk connector create "$CONNECTOR_NAME" "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY"
    fi
    sk connector status

    STAGE='8. Verify from the cloud'
    wait_ready link
    sk site status
    podman ps -a --filter name=skupper
    log "Setup commands completed. The cloud Listener must use routing key: $ROUTING_KEY"
    log 'Send an application request from the cloud namespace to verify the full connection.'
    log "CLI: $SKUPPER --platform podman --namespace $NAMESPACE"
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
