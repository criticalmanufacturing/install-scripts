#!/usr/bin/env bash
# Check native setup/retry behavior without changing host packages or services.
# shellcheck disable=SC2030,SC2031,SC2317
set -Eeuo pipefail
SCRIPT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/setup-saas-connector-ubuntu-native.sh
# shellcheck source=saas-connector/setup-saas-connector-ubuntu-native.sh
source "$SCRIPT"
TEST_DIR=$(mktemp -d)
trap 'find "$TEST_DIR" -mindepth 1 -delete; rmdir "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat >"$TEST_DIR/link.yaml" <<'YAML'
kind: Link
spec:
  endpoints:
    - host: cloud.example.com
YAML

# A compatible installed router needs no compiler/packages on later runs.
(
    skrouterd() { printf '3.5.3\n'; }
    sudo() { fail 'an installed router must not trigger a build'; }
    install_router
)

(
    export HOME="$TEST_DIR/home" XDG_DATA_HOME="$TEST_DIR/data"
    CALLS="$TEST_DIR/calls"
    STATE="$XDG_DATA_HOME/skupper/namespaces/default"
    mkdir -p "$HOME" "$STATE"
    check_ubuntu() { :; }
    sudo() { printf 'sudo %s\n' "$*" >>"$CALLS"; }
    systemctl() { printf 'systemctl %s\n' "$*" >>"$CALLS"; }
    sleep() { :; }
    install_cli() {
        mkdir -p "$HOME/.local/bin"
        printf '#!/usr/bin/env bash\nprintf "2.2.3\\n"\n' >"$SKUPPER"
        chmod +x "$SKUPPER"
    }
    install_router() { :; }
    nc() { return 0; }
    sk() {
        printf 'sk %s\n' "$*" >>"$CALLS"
        case "$1 $2" in
            'site create') mkdir -p "$STATE/input/resources"; touch "$STATE/input/resources/Site-$3.yaml" ;;
            'connector create') touch "$STATE/input/resources/Connector-$3.yaml" ;;
            'system start')
                mkdir -p "$STATE/runtime/resources" "$STATE/internal"
                printf 'platform: linux\n' >"$STATE/internal/platform.yaml" ;;
        esac
    }
    args=(--link-file "$TEST_DIR/link.yaml" --app-ip 192.168.1.14 --app-port 3000)
    (main "${args[@]}" --connector-name first-app) >"$TEST_DIR/first" 2>&1
    (main "${args[@]}" --connector-name second-app) >"$TEST_DIR/second" 2>&1
    (main "${args[@]}" --connector-name first-app --app-port 3001) >"$TEST_DIR/update" 2>&1
    [[ $(rg -c 'sk site create' "$CALLS") == 1 ]] || fail 'site recreated'
    [[ $(rg -c 'sk system start' "$CALLS") == 1 ]] || fail 'initial start'
    [[ $(rg -c 'sk system reload' "$CALLS") == 2 ]] || fail 'later runs must reload'
    [[ -f $STATE/input/resources/Connector-first-app.yaml && -f $STATE/input/resources/Connector-second-app.yaml ]] || fail 'existing app lost'
    rg -q 'connector update first-app --port 3001' "$CALLS" || fail 'app not updated'
    rg -q 'systemctl --user is-active skupper-default.service' "$CALLS" || fail 'native service check'
    if rg -q 'podman|docker|system install|skupper-controller' "$CALLS"; then fail 'container runtime/controller used'; fi
    [[ $(stat -c '%a' "$TEST_DIR/link.yaml") == 600 ]] || fail 'link permissions'

    # Reject a container namespace before changing any resources or packages.
    cp "$CALLS" "$TEST_DIR/before"
    printf 'platform: podman\n' >"$STATE/internal/platform.yaml"
    if (main "${args[@]}" --connector-name first-app) >"$TEST_DIR/error" 2>&1; then fail 'container namespace accepted'; fi
    cmp -s "$CALLS" "$TEST_DIR/before" || fail 'container installation changed'
    rg -q 'already uses a container platform' "$TEST_DIR/error" || fail 'missing platform error'
)
printf 'PASS: native start, second app, retry/update, router reuse and container-platform rejection\n'
