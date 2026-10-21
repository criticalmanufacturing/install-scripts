#!/usr/bin/env bash
# A container bootstrap, deliberately separate from the VM's Podman/systemd setup.
set -Eeuo pipefail
set +x
umask 077
log() { printf '[saas-connector] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "Configuration failed at line $LINENO."' ERR

if [[ ${1:-} == --version ]]; then
    skupper version
    skrouterd --version
    exit 0
fi
(($# == 0)) || die 'Configure this image using environment variables; see the Helm values.'
[[ $EUID -ne 0 ]] || die 'Run as a non-root user (an arbitrary OpenShift UID is supported).'
: "${CONNECTOR_NAME:?CONNECTOR_NAME is required}"
: "${APP_IP:?APP_IP is required}"
: "${APP_PORT:?APP_PORT is required}"
SITE_NAME=${SITE_NAME:-$(hostname | tr '[:upper:]' '[:lower:]')}
NAMESPACE=${NAMESPACE:-default}
ROUTING_KEY=${ROUTING_KEY:-$CONNECTOR_NAME}
LINK_FILE=${LINK_FILE:-/input/link.yaml}
TIMEOUT=${TIMEOUT:-180}
[[ -s $LINK_FILE && -r $LINK_FILE ]] || die 'The mounted link file is missing, empty or unreadable.'
for name in "$SITE_NAME" "$NAMESPACE" "$CONNECTOR_NAME"; do
    [[ ${#name} -le 63 && $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid site, namespace or connector name: $name"
done
if [[ ! $APP_PORT =~ ^[0-9]{1,5}$ ]] || ((10#$APP_PORT < 1 || 10#$APP_PORT > 65535)); then die 'APP_PORT must be 1..65535.'; fi
APP_PORT=$((10#$APP_PORT))
if [[ ! $TIMEOUT =~ ^[0-9]{1,4}$ ]] || ((10#$TIMEOUT < 1 || 10#$TIMEOUT > 3600)); then die 'TIMEOUT must be 1..3600 seconds.'; fi
TIMEOUT=$((10#$TIMEOUT))

# This entire directory is generated state in a dedicated, disposable volume.
# Reset only our namespace after a container restart; never modify the input mount.
site_dir="/output/namespaces/$NAMESPACE"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" /output/namespaces
if [[ -e $site_dir ]]; then
    [[ -d $site_dir && ! -L $site_dir && -O $site_dir ]] || die 'Generated namespace directory is not owned by this user.'
    find "$site_dir" -mindepth 1 -delete
fi
mkdir -p "$site_dir/input/resources"
cp -- "$LINK_FILE" "$site_dir/link.yaml"
chmod 600 "$site_dir/link.yaml"

sk() { timeout --foreground "${TIMEOUT}s" skupper --platform linux --namespace "$NAMESPACE" "$@"; }
log "Rendering site=$SITE_NAME connector=$CONNECTOR_NAME routing-key=$ROUTING_KEY target=$APP_IP:$APP_PORT"
sk site create "$SITE_NAME"
sk system apply -f "$site_dir/link.yaml"
sk connector create "$CONNECTOR_NAME" "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY"
# In container mode this renders configuration and certificates, without systemd.
sk system start
config="$site_dir/runtime/router/skrouterd.json"
[[ -s $config ]] || die 'Skupper did not generate the router configuration.'
log 'Starting the native router. Cloud connections reconnect automatically.'
exec skrouterd -c "$config"
