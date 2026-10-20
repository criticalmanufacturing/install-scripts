#!/usr/bin/env bash
# Provision one rootless Skupper 2.2.3 Podman site on an Ubuntu customer VM.
# Run as the permanent VM login user, NEVER with sudo bash or as root.
# Privilege is requested only for Ubuntu packages, lingering, and /etc/hosts.
# No Kubernetes commands are run. See README.md for scope and recovery notes.
# Reviewed against upstream tag 2.2.3 (bbf5c63b45c6ff7a19022693e420ee48835ce971).

set -Eeuo pipefail
set +x                         # Link credentials must never appear in xtrace.
umask 077                      # New private keys, staging files, and state are private.
export LC_ALL=C

VERSION=2.2.3
STAGE=initialization
WORK_DIR=
DRY_RUN=0
LINK_FILE='' CLOUD_HOST='' CLOUD_IP='' APP_IP='' APP_PORT=''
SITE_NAME='' NAMESPACE='' CONNECTOR_NAME=application ROUTING_KEY=''
CONTROLLER_PAUSED=0
TIMEOUT=180

log() { printf '[%s] %s\n' "$STAGE" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
cleanup() {
    if ((CONTROLLER_PAUSED)); then
        systemctl --user start skupper-controller.service || log 'ERROR: restart skupper-controller.service manually.'
    fi
    # Only remove this process's mktemp directory, never persistent site state.
    if [[ -n ${WORK_DIR:-} && -d $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
}
on_error() {
    local rc=$1 line=$2
    trap - ERR
    # Do not echo BASH_COMMAND: a future command could contain credential material.
    log "ERROR: step failed at script line $line (exit $rc). Fix the cause and rerun with the same names."
    exit "$rc"
}

check_ubuntu() {
    # FIRST step, including before argument handling or any package/privilege action.
    # ID_LIKE is intentionally ignored: Ubuntu derivatives are not supported.
    [[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release; Ubuntu is required.'
    local ID='' VERSION_ID=''
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == ubuntu ]] || die "Ubuntu is required (detected ${ID:-unknown})."
    case $VERSION_ID in
        24.04|26.04) ;;
        *) die 'Supported Ubuntu releases: 24.04 LTS and 26.04 LTS.' ;;
    esac
}

usage() {
    cat <<'USAGE'
Usage: bash setup-skupper-ubuntu.sh [options]

Required:
  --link-file PATH       Local YAML from Kubernetes `skupper link generate`.
                         Must include Link(s) and their TLS Secret(s), chmod 600.
  --cloud-host HOST      Cloud Skupper DNS hostname present in the Link YAML.
  --cloud-ip IP          Its unicast IPv4 or IPv6 address; updates /etc/hosts.
  --app-ip IP            Application's reachable unicast IPv4 or IPv6 address.
  --app-port PORT        Application TCP port, 1..65535.
  --routing-key NAME     Required shared routing key of the cloud Listener.

Optional:
  --site-name NAME       Default: vm-<hostname>-<machine/user hash>; stable on rerun.
  --namespace NAME       Default: site name. One site per user/namespace.
  --connector-name NAME  Default: application; stable resource name for updates.
  --timeout SECONDS      Per-step convergence timeout, 10..3600 (default: 180).
  --dry-run             Read-only input/YAML validation and plan; no sudo/network.
  -h, --help            Show this help (Ubuntu check still runs first).

Run from a direct SSH/login session as the permanent nonroot VM user with sudo.
Requires systemd, a local home directory, subordinate UID/GID ranges, and outbound
access to Ubuntu mirrors, GitHub release assets, Quay, and the YAML link endpoints.
Dry-run requires existing python3 + python3-yaml; real setup installs these.
Do not run with bash -x. Do not publish the credential-bearing link YAML.
USAGE
}

parse_args() {
    local option
    while (($#)); do
        option=$1
        case $option in
            --dry-run) DRY_RUN=1; shift; continue ;;
            -h|--help) usage; exit 0 ;;
            --link-file|--cloud-host|--cloud-ip|--app-ip|--app-port|--site-name|--namespace|--connector-name|--routing-key|--timeout)
                if (($# < 2)) || [[ -z $2 || $2 == --* ]]; then
                    die "Missing value for $option."
                fi
                case $option in
                    --link-file) LINK_FILE=$2 ;;
                    --cloud-host) CLOUD_HOST=${2,,} ;;
                    --cloud-ip) CLOUD_IP=$2 ;;
                    --app-ip) APP_IP=$2 ;;
                    --app-port) APP_PORT=$2 ;;
                    --site-name) SITE_NAME=$2 ;;
                    --namespace) NAMESPACE=$2 ;;
                    --connector-name) CONNECTOR_NAME=$2 ;;
                    --routing-key) ROUTING_KEY=$2 ;;
                    --timeout) TIMEOUT=$2 ;;
                esac
                shift 2 ;;
            *) die "Unknown argument: $option. Use --help." ;;
        esac
    done
    [[ -n $LINK_FILE && -n $CLOUD_HOST && -n $CLOUD_IP && -n $APP_IP && -n $APP_PORT && -n $ROUTING_KEY ]] ||
        die 'Required: --link-file, --cloud-host, --cloud-ip, --app-ip, --app-port, --routing-key. Use --help.'
    if [[ ! $APP_PORT =~ ^[0-9]{1,5}$ ]] || ((10#$APP_PORT < 1 || 10#$APP_PORT > 65535)); then die 'Application port must be 1..65535.'; fi
    APP_PORT=$((10#$APP_PORT))
    if [[ ! $TIMEOUT =~ ^[0-9]{1,4}$ ]] || ((10#$TIMEOUT < 10 || 10#$TIMEOUT > 3600)); then die 'Timeout must be 10..3600 seconds.'; fi
    TIMEOUT=$((10#$TIMEOUT))
}

check_user() {
    [[ $EUID -ne 0 ]] || die 'Run as the permanent nonroot VM login user, without sudo. The script invokes sudo only where needed.'
    USER_NAME=$(id -un)
    [[ $HOME == "$(getent passwd "$EUID" | cut -d: -f6)" && -d $HOME && -O $HOME ]] ||
        die "HOME must be the current user's existing, user-owned login home."
    # Keep all persistent paths predictable across SSH sessions and service restarts.
    [[ ${XDG_DATA_HOME:-$HOME/.local/share} == "$HOME/.local/share" &&
       ${XDG_CONFIG_HOME:-$HOME/.config} == "$HOME/.config" ]] || die 'Custom XDG data/config paths are not supported by this bootstrap.'
    local var
    for var in CONTAINER_HOST CONTAINER_CONNECTION CONTAINER_ENDPOINT DOCKER_HOST SKUPPER_OUTPUT_PATH; do
        [[ -z ${!var:-} ]] || die "Unset $var; setup must use this user's local rootless Podman."
    done
    while IFS= read -r var; do
        [[ $var == SKUPPER_PLATFORM || $var == SKUPPER_SYSTEM_RELOAD_TYPE ]] ||
            die "Unset $var to avoid overriding pinned Skupper defaults."
    done < <(compgen -e SKUPPER_ || true)
    export SKUPPER_PLATFORM=podman SKUPPER_SYSTEM_RELOAD_TYPE=auto
    export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
    export XDG_RUNTIME_DIR="/run/user/$EUID"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    DATA_DIR="$XDG_DATA_HOME/skupper"
    SKUPPER="$HOME/.local/bin/skupper"
}

set_names() {
    # Machine ID + UID makes defaults stable, while avoiding collisions across VMs.
    # Cloned images must regenerate /etc/machine-id before first use.
    local host_part identity name
    [[ -s /etc/machine-id ]] || die '/etc/machine-id is missing; initialize the VM identity first.'
    host_part=$(hostname -s | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-28)
    host_part=${host_part:-customer}
    identity=$( { cat /etc/machine-id; printf '%s' "$EUID"; } | sha256sum)
    SITE_NAME=${SITE_NAME:-vm-${host_part}-${identity:0:12}}
    NAMESPACE=${NAMESPACE:-$SITE_NAME}
    for name in "$SITE_NAME" "$NAMESPACE" "$CONNECTOR_NAME" "$ROUTING_KEY"; do
        [[ ${#name} -le 63 && $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
            die "Names/routing key must be DNS labels, 1..63 lowercase letters, digits or hyphens: $name"
    done
    NS_DIR="$DATA_DIR/namespaces/$NAMESPACE"
}

check_link_permissions() {
    # Refuse symlinks, special files, oversized input, or readable private keys.
    [[ -f $LINK_FILE && ! -L $LINK_FILE && -r $LINK_FILE && -O $LINK_FILE ]] ||
        die 'Link input must be a readable regular file owned by this user, not a symlink.'
    local mode size
    mode=$(stat -c '%a' -- "$LINK_FILE")
    size=$(stat -c '%s' -- "$LINK_FILE")
    (( (8#$mode & 0077) == 0 )) || die 'Link file is accessible to other users. Run chmod 600 on it.'
    ((size > 0 && size <= 1048576)) || die 'Link file must be nonempty and at most 1 MiB.'
}

helper() {
    # Embedded, self-contained Python performs structured parsing; never eval YAML.
    # Error messages intentionally omit YAML values and parser context (private keys).
    python3 - "$@" <<'PYHELPER'
import base64, ipaddress, json, os, pathlib, re, socket, stat, sys

def require(ok, message):
    if not ok:
        raise ValueError(message)

def label(value):
    return isinstance(value, str) and bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', value))

def address(value):
    require('%' not in value, 'Scoped IP addresses are not supported.')
    ip = ipaddress.ip_address(value)
    require(not (ip.is_unspecified or ip.is_multicast or ip.is_link_local or (ip.is_reserved and not ip.is_loopback)),
            'A reachable unicast IP address is required.')
    return ip

def documents(path):
    import yaml
    # Reject aliases, anchors and duplicate keys instead of accepting ambiguous input.
    class StrictLoader(yaml.SafeLoader):
        def compose_node(self, parent, index):
            require(not self.check_event(yaml.AliasEvent), 'YAML aliases are not allowed.')
            event = self.peek_event()
            require(getattr(event, 'anchor', None) is None, 'YAML anchors are not allowed.')
            return super().compose_node(parent, index)
        def construct_mapping(self, node, deep=False):
            keys = [self.construct_object(k, deep=deep) for k, _ in node.value]
            require(all(isinstance(k, str) for k in keys), 'YAML mapping keys must be strings.')
            require(len(keys) == len(set(keys)), 'Duplicate YAML mapping keys are not allowed.')
            return super().construct_mapping(node, deep=deep)
    return list(yaml.load_all(pathlib.Path(path).read_text(encoding='utf-8-sig'), Loader=StrictLoader))

def link_input(path, host, cloud_ip):
    # Permit exactly the standard `link generate` output: Link(s) and TLS Secret(s).
    # Reject Site/Connector/AccessToken or unrelated resources, rather than silently
    # applying a broader manifest. Namespace metadata is normalized by Skupper.
    docs = documents(path)
    require(1 <= len(docs) <= 32, 'Expected 1..32 YAML documents.')
    links, secrets, seen = [], {}, set()
    for doc in docs:
        require(isinstance(doc, dict), 'Every YAML document must be an object.')
        kind, api = doc.get('kind'), doc.get('apiVersion')
        require((kind, api) in [('Link', 'skupper.io/v2alpha1'), ('Secret', 'v1')],
                'Only Skupper v2alpha1 Link and v1 Secret documents are allowed. AccessTokens are not Link files.')
        name = doc.get('metadata', {}).get('name')
        require(label(name), 'Resource names must be DNS labels of at most 63 characters.')
        require((kind, name) not in seen, 'Duplicate resource in link file.')
        seen.add((kind, name))
        if kind == 'Link':
            spec = doc.get('spec', {})
            require(isinstance(spec, dict) and not (set(spec) - {'endpoints', 'tlsCredentials', 'cost'}),
                    'Link spec contains unsupported settings; review it before extending this bootstrap.')
            require(label(spec.get('tlsCredentials')), 'Link must name TLS credentials.')
            require(type(spec.get('cost', 1)) is int and 1 <= spec.get('cost', 1) <= 2147483647, 'Invalid link cost.')
            endpoints = spec.get('endpoints')
            require(isinstance(endpoints, list) and 1 <= len(endpoints) <= 16, 'Link needs 1..16 endpoints.')
            for ep in endpoints:
                require(isinstance(ep, dict), 'Invalid link endpoint.')
                # One supplied hosts mapping cannot safely describe unrelated hosts.
                require(str(ep.get('host', '')).lower() == host, 'Every link endpoint must use --cloud-host.')
                require(isinstance(ep.get('port'), str) and bool(re.fullmatch(r'[0-9]{1,5}', ep['port'])) and 1 <= int(ep['port']) <= 65535,
                        'Link endpoint port must be a quoted decimal string, as emitted by Skupper 2.2.3 link generate.')
                require(ep.get('name') in ('inter-router', 'edge'), 'Unsupported link endpoint role.')
            links.append(doc)
        else:
            require(doc.get('type') == 'kubernetes.io/tls', 'Expected a kubernetes.io/tls Secret.')
            data = doc.get('data', {})
            require(isinstance(data, dict) and set(data) == {'ca.crt', 'tls.crt', 'tls.key'}, 'TLS Secret must contain ca.crt, tls.crt and tls.key.')
            for key, value in data.items():
                raw = base64.b64decode(value, validate=True)
                marker = b'PRIVATE KEY-----' if key == 'tls.key' else b'CERTIFICATE-----'
                require(marker in raw, 'TLS Secret contains invalid PEM material.')
            secrets[name] = doc
    require(links, 'No Link resource was supplied.')
    used = {link['spec']['tlsCredentials'] for link in links}
    require(used == set(secrets), 'Include exactly the TLS Secrets referenced by the supplied Links.')
    for link in links:
        for ep in link['spec']['endpoints']:
            print(link['metadata']['name'], ep['port'])

def status(path, kind, name, host, port, key, desired_path):
    obj = json.loads(pathlib.Path(path).read_text(encoding='utf-8-sig'))
    require(obj.get('kind') == kind and obj.get('metadata', {}).get('name') == name, 'Unexpected status object.')
    s = obj.get('status', {})
    if kind == 'Connector':
        spec = obj.get('spec', {})
        require(spec.get('host') == host and spec.get('port') == int(port) and spec.get('routingKey') == key,
                'Connector runtime has not converged to requested settings.')
        require(any(c.get('type') == 'Configured' and c.get('status') == 'True' for c in s.get('conditions', [])),
                'Connector is not configured yet.')
    else:
        if kind == 'Link':
            expected = [x for x in documents(desired_path) if x['kind'] == 'Link' and x['metadata']['name'] == name]
            require(len(expected) == 1 and obj.get('spec') == expected[0].get('spec'), 'Link runtime has not converged to requested settings.')
        require(s.get('status') == 'Ready', kind + ' is not Ready yet.')

try:
    cmd, *a = sys.argv[1:]
    if cmd == 'inputs':
        host, cloud, app = a
        require(len(host) <= 253 and '.' in host and all(label(part) for part in host.split('.')), 'Cloud hostname must be a valid lowercase FQDN without a trailing dot.')
        address(cloud)
        address(app)  # Loopback is allowed: Skupper 2.2.3 uses host networking.
    elif cmd == 'link':
        link_input(*a)
    elif cmd == 'status':
        status(*a)
    elif cmd == 'tcp':
        with socket.create_connection((a[0], int(a[1])), timeout=5):
            pass
    elif cmd == 'resolve':
        expected = ipaddress.ip_address(a[1])
        answers = {ipaddress.ip_address(x[4][0]) for x in socket.getaddrinfo(a[0], None, type=socket.SOCK_STREAM)}
        require(answers == {expected}, 'Hostname resolution does not exclusively match --cloud-ip; check NSS/DNS and hosts aliases.')
    elif cmd == 'inspect-controller':
        obj = json.loads(pathlib.Path(a[0]).read_text())[0]
        require(obj.get('Config', {}).get('Image') == 'quay.io/skupper/system-controller:2.2.3', 'Existing controller uses another image; use a dedicated user or perform a reviewed upgrade.')
        require('SKUPPER_SYSTEM_RELOAD_TYPE=auto' in obj.get('Config', {}).get('Env', []), 'Existing controller is not auto reload; see README.md recovery instructions.')
    elif cmd == 'router-hosts':
        text, host, expected = pathlib.Path(a[0]).read_text(), a[1], ipaddress.ip_address(a[2])
        found = []
        for line in text.splitlines():
            fields = line.partition('#')[0].split()
            if len(fields) >= 2 and host in [x.lower().rstrip('.') for x in fields[1:]]:
                found.append(ipaddress.ip_address(fields[0]))
        require(bool(found) and set(found) == {expected}, 'Router cloud hosts mapping is stale or missing.')
    elif cmd == 'namespace-empty':
        root = pathlib.Path(a[0])
        require(not any(root.glob('input/resources/*')) and not any(root.glob('runtime/resources/*')),
                'Namespace already has resources; choose a new namespace instead of adopting existing state.')
    elif cmd == 'snapshot':
        src, dst = a
        # O_NOFOLLOW + fstat close the shell precheck/open race; never chmod source.
        fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f:
            s = os.fstat(f.fileno())
            require(stat.S_ISREG(s.st_mode) and s.st_uid == os.getuid() and not s.st_mode & 0o077,
                    'Link source ownership/type/permissions changed; refusing input.')
            content = f.read(1048577)
            require(0 < len(content) <= 1048576, 'Invalid link input size.')
        fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(content)
    elif cmd == 'verify-applied':
        # 2.2.3 system apply may log per-resource errors and return zero. Compare
        # every resulting input object rather than trusting the exit status alone.
        source, directory, ns = a
        for expected in documents(source):
            kind, name = expected['kind'], expected['metadata']['name']
            prefix = {'Link': 'link', 'Secret': 'secret', 'Connector': 'connector'}[kind]
            actual = documents(str(pathlib.Path(directory) / (prefix + '-' + name + '.yaml')))[0]
            require(actual.get('kind') == kind and actual.get('apiVersion') == expected['apiVersion'], 'Applied resource kind/API differs.')
            require(actual['metadata']['name'] == name and actual['metadata'].get('namespace') == ns, 'Applied resource identity differs.')
            if kind == 'Secret':
                require(actual.get('type') == expected.get('type'), 'Applied TLS Secret type differs.')
            field = 'data' if kind == 'Secret' else 'spec'
            require(actual.get(field) == expected.get(field), 'Applied resource data differs from requested configuration.')
    else:
        raise ValueError('Unknown helper operation.')
except Exception as exc:
    # Only our controlled ValueError messages are safe to print; YAML exceptions
    # can contain snippets of credentials and must be reduced to a generic error.
    message = str(exc) if type(exc) is ValueError else 'Structured validation failed (' + type(exc).__name__ + '); check input format without exposing its credentials.'
    print('ERROR: ' + message, file=sys.stderr)
    sys.exit(1)
PYHELPER
}

install_packages() {
    command -v sudo >/dev/null || die 'sudo is required for package installation and host configuration.'
    sudo -v || die 'This login user requires sudo rights (use a terminal for password prompts).'
    # Distribution packages avoid unreviewed third-party repositories/installers.
    sudo apt-get -o DPkg::Lock::Timeout=120 update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
        podman uidmap \
        dbus-user-session ca-certificates curl python3 python3-yaml
}

check_session() {
    [[ -d /run/systemd/system && ! -e /.dockerenv && ! -e /run/.containerenv ]] ||
        die 'A full Ubuntu VM booted with systemd is required; containers are not supported.'
    [[ -d $XDG_RUNTIME_DIR && -O $XDG_RUNTIME_DIR && -S $XDG_RUNTIME_DIR/bus ]] ||
        die 'No user systemd session. Log out and SSH/login directly as this user, then rerun.'
    systemctl --user show-environment >/dev/null || die 'User systemd is unavailable; reconnect with a direct login session.'
}

check_subids() {
    # Ubuntu normally assigns these on user creation. Never guess a range that
    # could overlap another user or change mappings beneath existing containers.
    local file
    for file in /etc/subuid /etc/subgid; do
        awk -F: -v user="$USER_NAME" -v uid="$EUID" \
            '($1==user || $1==uid) && $2>=1 && $3>=65536 {found=1} END {exit !found}' "$file" ||
            die "$file needs an administrator-assigned nonoverlapping range of at least 65536 IDs for $USER_NAME. Assign it, log in again, then rerun."
    done
}

prepare_state() {
    # Private parent blocks traversal even when upstream creates files as 0644.
    # Refuse symlinks, foreign ownership, and preexisting broad access in all
    # Skupper state, rather than silently adopting another installation.
    local path
    for path in "$HOME/.local" "$HOME/.local/share" "$HOME/.local/bin" "$DATA_DIR"; do
        [[ ! -L $path ]] || die "Refusing symlinked state path: $path"
        [[ ! -e $path || ( -d $path && -O $path ) ]] || die "State directory is not owned by this user: $path"
    done
    mkdir -p -- "$HOME/.local/bin" "$DATA_DIR"
    chmod 700 -- "$DATA_DIR"
    [[ -z $(find "$DATA_DIR" -type l -print -quit) ]] || die 'Skupper state contains symlinks; review it before rerunning.'
    [[ -z $(find "$DATA_DIR" ! -uid "$EUID" -print -quit) ]] || die 'Skupper state has foreign-owned files; review it before rerunning.'
    # Serialize all namespaces for this user because the controller is shared.
    exec 9>"$DATA_DIR/.ubuntu-setup.lock"
    flock -n 9 || die 'Another setup process is running for this user.'
    mkdir -p -- "$NS_DIR/input/resources"
    chmod 700 -- "$NS_DIR" "$NS_DIR/input" "$NS_DIR/input/resources"
}

install_cli() {
    # Download an immutable release, not the rolling upstream install.sh.
    # Pinned SHA256 values are GitHub's official release-asset digests, reviewed
    # with 2.2.3. They protect against corruption or later asset replacement.
    local arch checksum asset current=
    case $(uname -m) in
        x86_64) arch=amd64; checksum=9eb77dab5f2659becaca53364a38df38746b1850788d2652ef2084fcc3b325ab ;;
        aarch64|arm64) arch=arm64; checksum=447de7721bd1f6f54c918c951dff5e7d3c660660dea7848cf269bb9cf0df6fa1 ;;
        *) die 'Supported architectures: x86_64 and aarch64/arm64.' ;;
    esac
    [[ ! -L $SKUPPER ]] || die 'Refusing to replace a symlink at ~/.local/bin/skupper.'
    if [[ -e $SKUPPER ]]; then
        [[ -f $SKUPPER && -O $SKUPPER && -x $SKUPPER ]] || die 'Existing Skupper executable has unsafe ownership/type/permissions.'
        current=$("$SKUPPER" version)
        [[ $current == "$VERSION" ]] || die "Existing private CLI is ${current:-unknown}, expected $VERSION. Review/remove it explicitly before rerunning."
        log "Reusing CLI $VERSION."
        return
    fi
    asset="skupper-cli-$VERSION-linux-$arch.tgz"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 300 --retry 3 \
        "https://github.com/skupperproject/skupper/releases/download/$VERSION/$asset" -o "$WORK_DIR/cli.tgz"
    printf '%s  %s\n' "$checksum" "$WORK_DIR/cli.tgz" | sha256sum --check --status || die 'Skupper archive SHA256 mismatch; refusing to execute it.'
    # Extract only the expected regular binary, never arbitrary archive paths.
    tar -xzf "$WORK_DIR/cli.tgz" -C "$WORK_DIR" --no-same-owner --no-same-permissions skupper
    [[ -f $WORK_DIR/skupper && ! -L $WORK_DIR/skupper ]] || die 'Release archive has no regular skupper binary.'
    install -m 0755 -- "$WORK_DIR/skupper" "$SKUPPER"
    [[ $("$SKUPPER" version) == "$VERSION" ]] || die 'Installed CLI version verification failed.'
}

sk() {
    # Explicit platform/namespace on every command prevents accidental use of a
    # Kubernetes context or a different local namespace. Bound hung CLI calls.
    timeout --foreground "${TIMEOUT}s" "$SKUPPER" --platform podman --namespace "$NAMESPACE" "$@"
}

update_hosts() {
    # Root executes only this fixed inline helper; never a user-writable .py file.
    # Keep nonmatching aliases and comments, remove all stale/duplicate matches,
    # and add one authoritative entry. Lock, back up, and atomically replace.
    sudo python3 -I - "$CLOUD_HOST" "$CLOUD_IP" <<'PYHOSTS'
import datetime, fcntl, ipaddress, os, pathlib, shutil, stat, sys, tempfile
host, ip = sys.argv[1:]
ip = str(ipaddress.ip_address(ip))
def transform(text):
    lines = []
    for line in text.splitlines():
        body, sep, comment = line.partition('#')
        fields = body.split()
        if len(fields) >= 2 and host in [x.lower().rstrip('.') for x in fields[1:]]:
            aliases = [x for x in fields[1:] if x.lower().rstrip('.') != host]
            if aliases:
                lines.append(fields[0] + '\t' + ' '.join(aliases) + ((' #' + comment) if sep else ''))
            elif sep and comment.strip() and comment.strip() != 'managed by setup-skupper-ubuntu':
                lines.append('#' + comment)
        else:
            lines.append(line)
    lines.append(ip + '\t' + host + ' # managed by setup-skupper-ubuntu')
    return '\n'.join(lines) + '\n'

path = pathlib.Path('/etc/hosts')
lockfd = os.open('/etc/.skupper-hosts.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
with os.fdopen(lockfd, 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
        raise SystemExit('ERROR: /etc/hosts must be a root-owned regular file (no symlinks).')
    before = path.read_text()
    after = transform(before)
    if after != before:
        backup = '/etc/hosts.skupper-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ') + '.bak'
        shutil.copy2(path, backup)
        fd, temp = tempfile.mkstemp(prefix='.hosts.skupper-', dir='/etc')
        try:
            with os.fdopen(fd, 'w') as f:
                f.write(after)
                f.flush()
                os.fchown(f.fileno(), st.st_uid, st.st_gid)
                os.fchmod(f.fileno(), stat.S_IMODE(st.st_mode))
                os.fsync(f.fileno())
            os.replace(temp, path)  # Fail safely on bind mounts; never truncate.
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        print('Updated /etc/hosts; backup: ' + backup)
    else:
        print('/etc/hosts already matches.')
PYHOSTS
    helper resolve "$CLOUD_HOST" "$CLOUD_IP"
}

ensure_controller() {
    local container="$USER_NAME-skupper-controller"
    # Reject existing wrong-version/manual controllers instead of removing a
    # controller shared by other sites. 2.2.3 install does not update it in place.
    if podman container exists "$container"; then
        podman inspect "$container" >"$WORK_DIR/controller.json"
        helper inspect-controller "$WORK_DIR/controller.json"
    else
        sk system install --reload-type auto
    fi
    systemctl --user enable --now skupper-controller.service
    systemctl --user is-enabled --quiet skupper-controller.service
    systemctl --user is-active --quiet skupper-controller.service
    podman inspect "$container" >"$WORK_DIR/controller.json"
    helper inspect-controller "$WORK_DIR/controller.json"
    [[ $(podman inspect --format '{{.State.Running}}' "$container") == true ]] || die 'System controller container is not running.'
}

router_hosts_match() {
    podman exec "$NAMESPACE-skupper-router" cat /etc/hosts >"$WORK_DIR/router-hosts" || return 1
    helper router-hosts "$WORK_DIR/router-hosts" "$CLOUD_HOST" "$CLOUD_IP"
}

refresh_router_hosts() {
    # Podman snapshots /etc/hosts when a container is created. A changed cloud
    # IP needs a router recreation, not just an edit on the VM or a restart.
    # Use the supported namespace reload while the dynamic controller is paused
    # to avoid two renderers racing. Only a namespace owned by this script enters
    # this path; its active application connections will be interrupted briefly.
    if ! router_hosts_match 2>/dev/null; then
        log 'Refreshing router after cloud hosts mapping change (brief connection interruption).'
        CONTROLLER_PAUSED=1
        systemctl --user stop skupper-controller.service
        sk system reload
        systemctl --user start skupper-controller.service
        CONTROLLER_PAUSED=0
        router_hosts_match || die 'Recreated router still lacks the cloud mapping; review Podman base_hosts_file/no_hosts configuration.'
    fi
}

wait_resource() {
    local kind=$1 name=$2 start=$SECONDS
    while ((SECONDS - start < TIMEOUT)); do
        if sk "${kind,,}" status "$name" -o json >"$WORK_DIR/status.json" 2>"$WORK_DIR/status.err" &&
            helper status "$WORK_DIR/status.json" "$kind" "$name" "$APP_IP" "$APP_PORT" "$ROUTING_KEY" "$WORK_DIR/link.yaml" 2>/dev/null; then
            log "$kind $name validated."
            return
        fi
        sleep 2
    done
    # Safe status text has no credentials; never print the status JSON for Link.
    sk "${kind,,}" status "$name" || true
    die "$kind $name did not converge within ${TIMEOUT}s. Inspect the user controller journal and network/firewall/TLS configuration."
}

apply_resources() {
    # A namespace with an unrelated site must never be overwritten. Record a
    # private ownership marker BEFORE create so interrupted first runs can resume.
    local marker="$NS_DIR/.ubuntu-setup-site" link port
    if [[ -e $marker ]]; then
        [[ $(cat "$marker") == "$SITE_NAME" ]] || die 'This namespace is managed with another site name; use the original name or a different namespace.'
    else
        helper namespace-empty "$NS_DIR"
        printf '%s\n' "$SITE_NAME" >"$marker"
    fi
    if ! sk site status "$SITE_NAME" >"$WORK_DIR/site-existing.txt" 2>/dev/null; then
        sk site create "$SITE_NAME"
    fi
    wait_resource Site "$SITE_NAME"

    # Compare desired objects with persistent inputs to avoid unnecessary rewrite
    # and container reloads on identical reruns. This also repairs partial applies.
    if ! helper verify-applied "$WORK_DIR/link.yaml" "$NS_DIR/input/resources" "$NAMESPACE" 2>/dev/null; then
        sk system apply -f "$WORK_DIR/link.yaml"
    fi
    helper verify-applied "$WORK_DIR/link.yaml" "$NS_DIR/input/resources" "$NAMESPACE"

    # Generate via the versioned CLI, then apply declaratively for create/update.
    # This avoids interpreting any status failure as permission to delete a resource.
    sk connector generate "$CONNECTOR_NAME" "$APP_PORT" --host "$APP_IP" --routing-key "$ROUTING_KEY" >"$WORK_DIR/connector.yaml"
    if ! helper verify-applied "$WORK_DIR/connector.yaml" "$NS_DIR/input/resources" "$NAMESPACE" 2>/dev/null; then
        sk system apply -f "$WORK_DIR/connector.yaml"
    fi
    helper verify-applied "$WORK_DIR/connector.yaml" "$NS_DIR/input/resources" "$NAMESPACE"
    # Dynamic controller starts the router and processes resources automatically.
    # No system start/reload is needed in auto mode.
    wait_resource Connector "$CONNECTOR_NAME"
    refresh_router_hosts
    while read -r link port; do
        wait_resource Link "$link"
    done < <(sort -u "$WORK_DIR/endpoints.txt" | awk '!seen[$1]++')
    wait_resource Connector "$CONNECTOR_NAME"
}

main() {
    STAGE='Ubuntu check'
    check_ubuntu
    trap cleanup EXIT
    trap 'on_error "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    STAGE=preflight
    parse_args "$@"
    check_user
    set_names
    check_link_permissions
    check_session
    check_subids
    case $(uname -m) in x86_64|aarch64|arm64) ;; *) die 'Unsupported CPU architecture.' ;; esac

    if ((DRY_RUN)); then
        if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
            die 'Dry-run needs python3 and python3-yaml already installed; it will not install dependencies.'
        fi
        helper inputs "$CLOUD_HOST" "$CLOUD_IP" "$APP_IP"
        helper link "$LINK_FILE" "$CLOUD_HOST" "$CLOUD_IP" >/dev/null
        log "DRY RUN: site=$SITE_NAME namespace=$NAMESPACE connector=$CONNECTOR_NAME routing-key=$ROUTING_KEY"
        log "Would install Ubuntu packages and pinned CLI $VERSION; enable rootless socket/lingering and controller auto reload; update hosts; apply links; reconcile connector $APP_IP:$APP_PORT; validate readiness."
        log 'No files changed, packages installed, credentials consumed, sudo used, or network probes made. This is not a runtime readiness test.'
        return
    fi

    # Validate syntax before apt/sudo when Python is already present. PyYAML is
    # installed only if missing; it is needed to validate the credential bundle.
    if command -v python3 >/dev/null; then
        helper inputs "$CLOUD_HOST" "$CLOUD_IP" "$APP_IP"
        if python3 -c 'import yaml' 2>/dev/null; then
            helper link "$LINK_FILE" "$CLOUD_HOST" "$CLOUD_IP" >/dev/null
        fi
    fi
    STAGE=packages
    install_packages
    STAGE='input validation'
    WORK_DIR=$(mktemp -d /tmp/skupper-ubuntu.XXXXXXXX)
    helper inputs "$CLOUD_HOST" "$CLOUD_IP" "$APP_IP"
    helper snapshot "$LINK_FILE" "$WORK_DIR/link.yaml"
    helper link "$WORK_DIR/link.yaml" "$CLOUD_HOST" "$CLOUD_IP" >"$WORK_DIR/endpoints.txt"
    # Check reachability before touching site state; TCP probes send no payload.
    helper tcp "$APP_IP" "$APP_PORT" || die 'Application TCP port is unreachable from this VM.'
    while read -r _ port; do
        helper tcp "$CLOUD_IP" "$port" || die "Cloud TCP port $port from the link YAML is unreachable."
    done < <(sort -uk2,2 "$WORK_DIR/endpoints.txt")

    STAGE='rootless Podman'
    prepare_state
    sudo loginctl enable-linger "$USER_NAME"
    [[ $(loginctl show-user "$USER_NAME" -p Linger --value) == yes ]] || die 'Lingering did not enable.'
    systemctl --user enable --now podman.socket
    # Router containers use restart=always. This packaged oneshot service starts
    # them after reboot; lingering alone only keeps the user service manager alive.
    systemctl --user enable podman-restart.service
    systemctl --user is-enabled --quiet podman-restart.service
    systemctl --user is-active --quiet podman.socket
    [[ -S $XDG_RUNTIME_DIR/podman/podman.sock ]] || die 'Rootless Podman API socket is missing.'
    [[ $(podman info --format '{{.Host.Security.Rootless}}') == true ]] || die 'Podman is not rootless.'
    [[ $(podman info --format '{{.Host.CgroupsVersion}}') == v2 ]] || die 'cgroup v2 is required.'
    local pv
    pv=$(podman --version | awk '{print $3}')
    [[ $(printf '%s\n' 4.9.0 "$pv" | sort -V | head -n1) == 4.9.0 ]] || die 'Podman >=4.9 is required.'
    podman unshare true || die 'Rootless user namespaces failed; check subordinate IDs and Ubuntu security policy.'

    STAGE='CLI installation'
    install_cli
    STAGE='cloud hostname'
    update_hosts
    STAGE='system controller'
    ensure_controller
    STAGE='site and services'
    apply_resources
    STAGE='final validation'
    helper tcp "$APP_IP" "$APP_PORT"
    systemctl --user is-enabled --quiet podman.socket
    systemctl --user is-active --quiet skupper-controller.service
    [[ $(podman inspect --format '{{.State.Running}}' "$NAMESPACE-skupper-router") == true ]] || die 'Site router is not running.'
    # Container /etc/hosts is usually a snapshot of the host file. Verify the
    # actual running router to catch stale mappings on reruns after an IP change.
    router_hosts_match || die 'Router hosts mapping validation failed.'
    systemctl --user is-enabled --quiet podman-restart.service
    [[ $(podman inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$NAMESPACE-skupper-router") == always ]] ||
        die 'Router restart policy is not always; reboot recovery is not configured.'
    [[ $(podman inspect --format '{{.HostConfig.NetworkMode}}' "$NAMESPACE-skupper-router") == host ]] ||
        die 'Router must use host networking to reach the supplied application address.'
    log "SUCCESS: site=$SITE_NAME namespace=$NAMESPACE connector=$CONNECTOR_NAME routing-key=$ROUTING_KEY target=$APP_IP:$APP_PORT"
    log "CLI: $SKUPPER. Use --platform podman --namespace $NAMESPACE for subsequent commands."
    log 'Connector is configured; Kubernetes must have a listener with the same routing key. Validate the application from a Kubernetes client to confirm end-to-end behavior.'
}

# Sourcing exposes functions for isolated tests without executing provisioning.
# Also supports bash -s --, though downloading and checking the complete file is safer.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
