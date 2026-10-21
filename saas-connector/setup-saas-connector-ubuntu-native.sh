#!/usr/bin/env bash
# Native Linux alternative: run skrouterd under systemd, without a container runtime.
# Run as the normal VM login user, without sudo bash.
set -Eeuo pipefail
set +x
umask 077

readonly SKUPPER_VERSION=2.2.3
readonly ROUTER_VERSION=3.5.3
SITE_NAME=${SITE_NAME:-} NAMESPACE=${NAMESPACE:-} LINK_FILE=${LINK_FILE:-}
CONNECTOR_NAME=${CONNECTOR_NAME:-} ROUTING_KEY=${ROUTING_KEY:-}
APP_IP=${APP_IP:-} APP_PORT=${APP_PORT:-} CLOUD_HOST=${CLOUD_HOST:-} CLOUD_IP=${CLOUD_IP:-}
TIMEOUT=${TIMEOUT:-180} WORK_DIR='' STAGE='options'

log() { printf '\n[%s] %s\n' "$STAGE" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
cleanup() { if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }

usage() {
    cat <<'HELP'
Usage: bash setup-saas-connector-ubuntu-native.sh [options]
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
  --timeout SECONDS      Timeout for Skupper commands (default: 180)
  -h, --help             Show this help

Run as a normal Ubuntu 24.04/26.04 user with sudo access and a systemd login.
No Docker or Podman is used. A missing native router is built from source once.
The installer is Bash; Python is an upstream router dependency.
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
    [[ ! -e /run/.containerenv && ! -e /.dockerenv ]] || die 'Run directly on an Ubuntu VM, outside a container.'
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

install_router() {
    if command -v skrouterd >/dev/null; then
        [[ $(skrouterd --version) == "$ROUTER_VERSION" ]] || die "Existing skrouterd must be version $ROUTER_VERSION."
        return
    fi
    log 'Building the native router and its Proton dependency. This first installation takes a few minutes.'
    sudo apt-get install -y build-essential cmake ninja-build pkg-config python3-dev \
        libsasl2-dev libssl-dev libnghttp2-dev libwebsockets-dev libunwind-dev
    local proton="$WORK_DIR/proton" router="$WORK_DIR/router"
    mkdir -p "$proton" "$router"
    # Same Proton revision used by the upstream router 3.5.3 build.
    curl -fL --retry 3 -o "$WORK_DIR/proton.tgz" \
        https://codeload.github.com/apache/qpid-proton/tar.gz/e5d5c2badb964684bf41ba509a110bf06a24712a
    printf '%s  %s\n' d46132fc9278ab7726805138f06d52ec04d75a7d8921af98c6f51fe797293ef6 "$WORK_DIR/proton.tgz" | sha256sum --check --status
    tar -xzf "$WORK_DIR/proton.tgz" -C "$proton" --strip-components=1
    cmake -S "$proton" -B "$proton/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$proton/install" \
        -DBUILD_TLS=ON -DSSL_IMPL=openssl -DBUILD_STATIC_LIBS=ON \
        -DBUILD_BINDINGS='' -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
    cmake --build "$proton/build" --parallel 2
    cmake --install "$proton/build"
    curl -fL --retry 3 -o "$WORK_DIR/router.tgz" \
        "https://codeload.github.com/skupperproject/skupper-router/tar.gz/refs/tags/$ROUTER_VERSION"
    printf '%s  %s\n' b4b38c85b306d369ea4b27255a1b0ea2b7f62d3f46607e98295a8cc3e8cf70bb "$WORK_DIR/router.tgz" | sha256sum --check --status
    tar -xzf "$WORK_DIR/router.tgz" -C "$router" --strip-components=1
    # Upstream also writes a development config.sh in CMake's working directory.
    (
        cd "$WORK_DIR"
        cmake -S "$router" -B "$router/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH="$proton/install" -DProton_USE_STATIC_LIBS=ON \
        -DVERSION="$ROUTER_VERSION" -DBUILD_TESTING=OFF -DENABLE_FUZZ_TESTING=OFF \
        -DENABLE_WARNING_ERROR=OFF -DENABLE_PROFILE_GUIDED_OPTIMIZATION=OFF \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
    )
    cmake --build "$router/build" --parallel 2
    sudo cmake --install "$router/build"
    skrouterd --version
}

sk() { timeout --foreground "${TIMEOUT}s" "$SKUPPER" --platform linux --namespace "$NAMESPACE" "$@"; }

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
    export SKUPPER_PLATFORM=linux
    SKUPPER="$HOME/.local/bin/skupper"
    local site_dir="${XDG_DATA_HOME:-$HOME/.local/share}/skupper/namespaces/$NAMESPACE"
    local resources="$site_dir/input/resources" service="skupper-$NAMESPACE.service"
    if [[ -f $site_dir/internal/platform.yaml ]] && ! awk '$1=="platform:" && $2=="linux" { found=1 } END { exit !found }' "$site_dir/internal/platform.yaml"; then
        die 'This namespace already uses a container platform. Use this installer on a fresh native installation.'
    fi
    log "Site: $SITE_NAME | Namespace: $NAMESPACE | Connector: $CONNECTOR_NAME | Application: $APP_IP:$APP_PORT"
    log "Cloud: $CLOUD_HOST | IP override: ${CLOUD_IP:-none (existing DNS)}"

    STAGE='2. Ubuntu prerequisites'
    sudo true
    sudo apt-get update
    sudo apt-get install -y curl ca-certificates tar dbus-user-session netcat-openbsd
    systemctl --user is-active default.target
    sudo loginctl enable-linger "$(id -un)"

    STAGE='3. Skupper CLI and native router'
    WORK_DIR=$(mktemp -d)
    export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:$PATH"
    install_cli
    install_router
    "$SKUPPER" version

    STAGE='4. Cloud hostname mapping'
    configure_hosts
    STAGE='5. Skupper site'
    if [[ ! -f $resources/Site-$SITE_NAME.yaml ]]; then
        sk site create "$SITE_NAME"
    fi

    STAGE='6. Import cloud link'
    chmod 600 "$LINK_FILE"
    sk system apply -f "$LINK_FILE"

    STAGE='7. Application connector'
    nc -z -w 5 "$APP_IP" "$APP_PORT" || die 'The application TCP port is unreachable from this VM.'
    if [[ -f $resources/Connector-$CONNECTOR_NAME.yaml ]]; then
        sk connector update "$CONNECTOR_NAME" --port "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY"
    else
        sk connector create "$CONNECTOR_NAME" "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY"
    fi
    STAGE='8. Start the native router'
    # Linux has no auto controller: start once, or rebuild/restart on later runs.
    # Reload keeps the existing connectors when another application is added.
    if [[ -d $site_dir/runtime/resources ]]; then
        sk system reload
    else
        sk system start
    fi
    sleep 2
    if ! systemctl --user is-active "$service"; then
        journalctl --user -u "$service" -n 50 --no-pager >&2 || true
        die 'The native router service did not start.'
    fi
    sk site status
    sk link status
    sk connector status
    log "Setup commands completed. The cloud Listener must use routing key: $ROUTING_KEY"
    log 'Linux CLI status describes rendered resources; it does not prove a live cloud connection.'
    log 'Send an application request from the cloud namespace to verify the full connection.'
    log "Router logs: journalctl --user -u $service -n 50"
    log "CLI: $SKUPPER --platform linux --namespace $NAMESPACE"
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
