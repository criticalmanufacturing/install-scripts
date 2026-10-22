#!/usr/bin/env bash
set -Eeuo pipefail
installer=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/install.sh
bash_bin=$(command -v bash)
command -v python3 >/dev/null || { printf 'Python 3 is required for the offline terminal tests.\n' >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Run the actual installer from a pipe while a separate controlling terminal
# handles its prompts, matching the public download-and-run command.
cat >"$test_dir/run-pty.py" <<'PYTHON'
import errno
import fcntl
import os
import select
import signal
import subprocess
import sys
import termios
import time

with open(sys.argv[1], "rb") as source:
    script = source.read()
command = ["/bin/bash", "-s", "--", *sys.argv[2:]]
if os.environ.get("TEST_NO_TTY") == "yes":
    result = subprocess.run(command, input=script, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True,
                            timeout=20, check=False)
    sys.stdout.buffer.write(result.stdout)
    sys.exit(result.returncode)

master, slave = os.openpty()

def attach_terminal():
    os.setsid()
    fcntl.ioctl(1, termios.TIOCSCTTY, 0)

process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=slave,
                           stderr=slave, preexec_fn=attach_terminal)
os.close(slave)
process.stdin.write(script)
process.stdin.close()
answers = os.environ["TEST_ANSWERS"].splitlines()
prompts = [b"Install into this cluster?", b"Registry username:", b"Registry token:"]
output = bytearray()
answered = 0
deadline = time.monotonic() + 20
try:
    while True:
        if time.monotonic() > deadline:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            sys.stdout.buffer.write(output)
            print("\nFAIL: terminal test exceeded its deadline")
            sys.exit(124)
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            output.extend(data)
            if answered < len(answers) and prompts[answered] in output:
                os.write(master, answers[answered].encode() + b"\n")
                answered += 1
        elif process.poll() is not None:
            break
finally:
    os.close(master)
sys.stdout.buffer.write(bytes(output).replace(b"\r\n", b"\n"))
sys.exit(process.wait())
PYTHON
mkdir "$test_dir/bin"
cat >"$test_dir/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
tool=${0##*/}
for arg in "$@"; do
    [[ $arg != *"$TEST_TOKEN"* && $arg != *"$TEST_AUTH"* ]] || exit 90
done
printf '%s' "$tool" >>"$TEST_ARGS"
printf ' %q' "$@" >>"$TEST_ARGS"
printf '\n' >>"$TEST_ARGS"
record() { printf '%s\n' "$1" >>"$TEST_EVENTS"; }
assert_registry_credentials() {
    python3 - "$1" <<'PYTHON'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as credentials:
    config = json.load(credentials)
assert config == {"auths": {os.environ["TEST_REGISTRY"]: {"auth": os.environ["TEST_AUTH"]}}}, "wrong registry credentials"
PYTHON
}
assert_anonymous_pull_secrets() {
    [[ ${TEST_ANONYMOUS:-no} == yes ]] || return 0
    local previous='' last_values=''
    for argument in "$@"; do
        if [[ $previous == --values ]]; then last_values=$argument; fi
        previous=$argument
    done
    [[ -f $last_values && $last_values != ./app-values.yaml ]] || exit 106
    [[ $(stat -c %a "$last_values") == 600 ]] || exit 107
    grep -Fxq 'imagePullSecrets: []' "$last_values" || exit 108
    record "helm:anonymous-$1"
}
case $tool in
    helm)
        case $1 in
            version) printf '%s\n' "${TEST_HELM_VERSION:-v3.18.0}" ;;
            registry)
                record helm:login
                [[ $* == *'--password-stdin'* ]] || exit 91
                token=$(cat)
                [[ $token == "$TEST_TOKEN" ]] || exit 92
                config=${!#}
                printf '%s\n' "${config%/*}" >>"$TEST_AUTH_DIRS"
                [[ $(stat -c %a "$config") == 600 ]] || exit 93
                [[ $(stat -c %a "${config%/*}") == 700 ]] || exit 94
                [[ $3 == "$TEST_REGISTRY" ]] || exit 95
                assert_registry_credentials "$config"
                assert_registry_credentials "$DOCKER_CONFIG/config.json"
                [[ ${TEST_FAILURE:-} != login ]] || exit 1 ;;
            pull)
                record helm:pull
                [[ $2 == "oci://$TEST_REGISTRY/criticalmanufacturing/charts/saas-connector" ]] || exit 102
                [[ ${TEST_FAILURE:-} != pull ]] || exit 1
                version=0.2.0
                destination=''
                config=''
                shift
                while (($#)); do
                    case $1 in
                        --version) version=$2; shift 2 ;;
                        --destination) destination=$2; shift 2 ;;
                        --registry-config) config=$2; shift 2 ;;
                        *) shift ;;
                    esac
                done
                [[ -d $destination ]] || exit 101
                [[ -f $config ]] || exit 103
                printf '%s\n' "${config%/*}" >>"$TEST_AUTH_DIRS"
                [[ $(stat -c %a "$config") == 600 ]] || exit 104
                [[ $(stat -c %a "${config%/*}") == 700 ]] || exit 105
                if grep -Fq "$TEST_AUTH" "$config"; then
                    assert_registry_credentials "$config"
                    assert_registry_credentials "$DOCKER_CONFIG/config.json"
                elif [[ ${TEST_ANONYMOUS:-no} != yes ]]; then
                    exit 1
                fi
                if ! grep -Fq "$TEST_AUTH" "$config"; then
                    python3 - "$config" "$DOCKER_CONFIG/config.json" <<'PYTHON'
import json
import os
import sys

for filename in sys.argv[1:]:
    with open(filename, encoding="utf-8") as credentials:
        config = json.load(credentials)
    assert config == {"auths": {os.environ["TEST_REGISTRY"]: {}}}, "anonymous configuration did not isolate selected registry"
PYTHON
                fi
                [[ ${TEST_PACKAGES:-} != missing ]] || exit 0
                if [[ ${TEST_PACKAGES:-} == mismatch ]]; then version=0.1.0; fi
                touch "$destination/saas-connector-$version.tgz"
                if [[ ${TEST_PACKAGES:-} == multiple ]]; then
                    touch "$destination/saas-connector-0.1.0.tgz"
                fi ;;
            template)
                record helm:template
                assert_anonymous_pull_secrets "$@"
                [[ -f $3 ]] || exit 96
                printf 'PRIVATE_RENDERED_LINK_FIXTURE\n'
                [[ ${TEST_FAILURE:-} != template ]] || exit 1 ;;
            upgrade)
                record helm:upgrade
                assert_anonymous_pull_secrets "$@"
                [[ -f $4 ]] || exit 97
                [[ ${TEST_FAILURE:-} != upgrade ]] || exit 1 ;;
            *) exit 98 ;;
        esac ;;
    kubectl)
        case "$1 ${2:-}" in
            'config current-context') printf 'customer-cluster\n' ;;
            'auth can-i')
                case "$3 ${4:-}" in
                    'get secrets')
                        record kubectl:access
                        [[ ${TEST_FAILURE:-} != access ]] || exit 1
                        printf 'yes\n' ;;
                    'create namespaces')
                        record kubectl:can-create-namespace
                        [[ " $* " == *' --all-namespaces '* ]] || exit 109
                        if [[ ${TEST_CREATE_NAMESPACE:-yes} == yes ]]; then printf 'yes\n'; else printf 'no\n'; exit 1; fi ;;
                    *) exit 99 ;;
                esac ;;
            'create namespace')
                record kubectl:namespace
                if [[ ${TEST_FAILURE:-} == namespace ]]; then printf 'Error from server (Forbidden): namespace creation denied\n' >&2; exit 1; fi
                if [[ ${TEST_NAMESPACE_EXISTS:-yes} == yes ]]; then printf 'Error from server (AlreadyExists): namespaces already exists\n' >&2; exit 1; fi
                touch "$TEST_NS_CREATED" ;;
            'create secret')
                record kubectl:secret
                for arg in "$@"; do
                    case $arg in
                        --from-file=.dockerconfigjson=*) assert_registry_credentials "${arg#--from-file=.dockerconfigjson=}" ;;
                    esac
                done
                if [[ ${TEST_NAMESPACE_EXISTS:-yes} == no && ! -f $TEST_NS_CREATED ]]; then
                    printf 'Error from server (NotFound): namespace does not exist\n' >&2
                    exit 1
                fi
                [[ ${TEST_FAILURE:-} != secret ]] || exit 1
                printf 'kind: Secret\n' ;;
            'apply -f')
                cat >/dev/null
                record kubectl:apply
                [[ ${TEST_FAILURE:-} != apply ]] || exit 1 ;;
            *) exit 99 ;;
        esac ;;
    sleep) record sleep ;;
    *) exit 100 ;;
esac
MOCK
chmod +x "$test_dir/bin/mock"
for tool in helm kubectl sleep; do ln -s mock "$test_dir/bin/$tool"; done
export PATH="$test_dir/bin:$PATH"
export TEST_TOKEN=synthetic-installer-test-token
TEST_AUTH=$(printf 'fixture-user:%s' "$TEST_TOKEN" | base64 | tr -d '\n')
export TEST_AUTH
input=$(printf 'y\nfixture-user\n%s\n' "$TEST_TOKEN")

new_case() {
    case_dir="$test_dir/$1"
    mkdir -p "$case_dir/work dir"
    printf 'connectorName: fixture\nappIp: app.example.test\nappPort: 7990\n' >"$case_dir/work dir/app-values.yaml"
    printf '# synthetic private link fixture\n' >"$case_dir/work dir/link.yaml"
    export TEST_ARGS="$case_dir/args" TEST_EVENTS="$case_dir/events" TEST_AUTH_DIRS="$case_dir/auth-dirs"
    export TEST_NS_CREATED="$case_dir/namespace-created"
    : >"$TEST_ARGS"
    : >"$TEST_EVENTS"
    : >"$TEST_AUTH_DIRS"
    export TEST_REGISTRY=criticalmanufacturing.io
    unset TEST_FAILURE TEST_NAMESPACE_EXISTS TEST_HELM_VERSION TEST_CREATE_NAMESPACE TEST_NO_TTY TEST_PACKAGES TEST_ANONYMOUS
}
run_installer() {
    local answers=$1
    shift
    if (cd "$case_dir/work dir" && TEST_ANSWERS="$answers" python3 "$test_dir/run-pty.py" "$installer" "$@") >"$case_dir/output" 2>&1; then
        result=0
    else
        result=$?
    fi
}
assert_private_cleanup() {
    local directory
    while IFS= read -r directory; do
        [[ ! -e $directory ]] || fail 'temporary registry credentials were retained'
    done <"$TEST_AUTH_DIRS"
    if grep -Fq -e "$TEST_TOKEN" -e "$TEST_AUTH" -e PRIVATE_RENDERED_LINK_FIXTURE "$case_dir/output" "$TEST_ARGS"; then
        fail 'credentials or rendered Link data appeared in output or command arguments'
    fi
}
assert_failed() {
    [[ $result != 0 ]] || fail 'expected failure'
    if grep -Fq 'Connector installed successfully.' "$case_dir/output"; then fail 'failure reported success'; fi
    assert_private_cleanup
}
assert_no_mutation() {
    if grep -Eq '^(kubectl:(namespace|secret|apply)|helm:upgrade)$' "$TEST_EVENTS"; then
        fail 'changed cluster resources before authentication and validation completed'
    fi
}
assert_selected_package() {
    local version=$1
    python3 - "$TEST_ARGS" "$version" <<'PYTHON'
import shlex
import sys

with open(sys.argv[1], encoding="utf-8") as arguments:
    commands = [shlex.split(line) for line in arguments]
render = [command[3] for command in commands if command[:2] == ["helm", "template"]]
install = [command[4] for command in commands if command[:3] == ["helm", "upgrade", "--install"]]
assert len(render) == len(install) == 1, "expected one chart rendering and installation"
assert render == install, "rendering and installation used different chart packages"
assert render[0].endswith("/saas-connector-" + sys.argv[2] + ".tgz"), "wrong selected chart package"
PYTHON
}
assert_registry_selection() {
    local version=$1 authenticated=$2
    python3 - "$TEST_ARGS" "$version" "$authenticated" <<'PYTHON'
import os
import shlex
import sys

with open(sys.argv[1], encoding="utf-8") as arguments:
    commands = [shlex.split(line) for line in arguments]
registry = os.environ["TEST_REGISTRY"]
for command in commands:
    if command[:2] == ["helm", "pull"]:
        assert command[2] == "oci://" + registry + "/criticalmanufacturing/charts/saas-connector", "chart crossed registries"
    if command[:3] == ["helm", "registry", "login"]:
        assert command[3] == registry, "login crossed registries"
for operation in ("template", "upgrade"):
    selected = [command for command in commands if command[:2] == ["helm", operation]]
    assert len(selected) == 1, "expected one " + operation
    command = selected[0]
    settings = {}
    for index, argument in enumerate(command[:-1]):
        if argument in ("--set", "--set-string", "--set-json"):
            key, value = command[index + 1].split("=", 1)
            settings[key] = value
    assert settings.get("image.repository") == registry + "/criticalmanufacturing/saas-connector", "image crossed registries"
    assert settings.get("image.tag") == sys.argv[2], "image tag differs from selected release"
    if sys.argv[3] == "yes":
        assert settings.get("imagePullSecrets[0].name") == "criticalmanufacturing-registry", "authenticated image omitted pull secret"
    else:
        assert not any(key.startswith("imagePullSecrets") for key in settings), "anonymous image retained a pull secret override"
if sys.argv[3] == "no":
    with open(os.environ["TEST_EVENTS"], encoding="utf-8") as events:
        recorded = events.read().splitlines()
    assert recorded.count("helm:anonymous-template") == 1, "rendering omitted private empty pull secret values"
    assert recorded.count("helm:anonymous-upgrade") == 1, "installation omitted private empty pull secret values"
PYTHON
}

new_case help
run_installer "$input" --help
[[ $result == 0 ]] || fail 'help failed'
if grep -Fq -- '--registry' "$case_dir/output"; then fail 'internal registry option appeared in help'; fi
[[ ! -s $TEST_ARGS ]] || fail 'help invoked tools'

invalid_registries=('' 'registry' 'https://registry.example.test' 'registry.example.test/path' 'user:token@registry.example.test'
    'registry.example.test?query=yes' 'registry.example.test#fragment' 'registry.example.test:'
    'registry.example.test:zero' 'registry.example.test:0' 'registry.example.test:65536'
    'registry.example.test:123456789012345678901234567890' 'registry.example.test:5443:5444'
    'registry example.test' '-registry.example.test' 'registry..example.test' 'registry.example.test-')
for index in "${!invalid_registries[@]}"; do
    new_case "invalid-registry-$index"
    run_installer "$input" --registry "${invalid_registries[index]}"
    assert_failed
    assert_no_mutation
    [[ ! -s $TEST_ARGS ]] || fail 'invalid registry was not rejected before invoking tools'
done

new_case missing-registry
run_installer "$input" --registry
assert_failed
[[ ! -s $TEST_ARGS ]] || fail 'missing registry was not rejected before invoking tools'

new_case registry-followed-by-option
run_installer "$input" --registry --version 0.0.1
assert_failed
[[ ! -s $TEST_ARGS ]] || fail 'registry consumed another option as its value'

new_case anonymous-registry
export TEST_REGISTRY=registry.example.test:5443 TEST_ANONYMOUS=yes
printf 'imagePullSecrets:\n  - name: stale-registry\n' >>"$case_dir/work dir/app-values.yaml"
run_installer y --registry "$TEST_REGISTRY"
[[ $result == 0 ]] || fail 'anonymous registry installation failed'
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 1 ]] || fail 'anonymous chart was downloaded more than once'
if grep -Eq '^(helm:login|kubectl:(secret|apply))$' "$TEST_EVENTS"; then fail 'anonymous registry required credentials or a pull secret'; fi
if grep -Eq 'Registry (username|token):' "$case_dir/output"; then fail 'anonymous registry prompted for credentials'; fi
assert_selected_package 0.2.0
assert_registry_selection 0.2.0 no
assert_private_cleanup

new_case anonymous-registry-without-port
export TEST_REGISTRY=registry.example.test TEST_ANONYMOUS=yes
run_installer y --registry "$TEST_REGISTRY" --version 0.0.1
[[ $result == 0 ]] || fail 'registry hostname without a port was rejected'
assert_selected_package 0.0.1
assert_registry_selection 0.0.1 no
assert_private_cleanup

new_case authenticated-registry
export TEST_REGISTRY=registry.example.test:5443
run_installer "$input" --registry "$TEST_REGISTRY" --version 0.0.1
[[ $result == 0 ]] || fail 'authenticated custom registry installation failed'
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 2 ]] || fail 'custom registry did not retry once after authentication'
[[ $(grep -Ec '^helm:(pull|login)$' "$TEST_EVENTS") == 3 ]] || fail 'unexpected custom registry authentication attempts'
[[ $(grep -E '^helm:(pull|login)$' "$TEST_EVENTS") == $'helm:pull\nhelm:login\nhelm:pull' ]] || fail 'custom registry authentication order was incorrect'
assert_selected_package 0.0.1
assert_registry_selection 0.0.1 yes
assert_private_cleanup

new_case custom-registry-pull-failure
export TEST_REGISTRY=registry.example.test:5443 TEST_FAILURE=pull
run_installer "$input" --registry "$TEST_REGISTRY"
assert_failed
assert_no_mutation
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 2 ]] || fail 'failed custom registry pull had unexpected retries'
if grep -Fq 'oci://criticalmanufacturing.io/' "$TEST_ARGS"; then fail 'failed custom registry pull fell back to customer registry'; fi

new_case custom-registry-login-failure
export TEST_REGISTRY=registry.example.test:5443 TEST_FAILURE=login
run_installer "$input" --registry "$TEST_REGISTRY"
assert_failed
assert_no_mutation
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 1 ]] || fail 'failed custom registry login retried chart download'
if grep -Fq 'oci://criticalmanufacturing.io/' "$TEST_ARGS"; then fail 'failed custom registry login fell back to customer registry'; fi

new_case latest-version
run_installer "$input"
[[ $result == 0 ]] || fail 'latest stable installation failed'
grep -Fq 'Version: latest stable' "$case_dir/output" || fail 'latest stable default was not shown before confirmation'
grep -Fiq 'Version: 0.2.0' "$case_dir/output" || fail 'actual selected version was not shown'
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 1 ]] || fail 'latest chart was resolved more than once'
grep -Fq 'helm pull oci://criticalmanufacturing.io/criticalmanufacturing/charts/saas-connector ' "$TEST_ARGS" || fail 'incorrect latest chart repository'
if grep '^helm pull ' "$TEST_ARGS" | grep -Fq -- '--version'; then fail 'latest chart pull included a version constraint'; fi
assert_selected_package 0.2.0
assert_private_cleanup

new_case latest-pull-failure
export TEST_FAILURE=pull
run_installer "$input"
assert_failed
assert_no_mutation
[[ $(grep -c '^helm pull ' "$TEST_ARGS") == 1 ]] || fail 'failed latest pull retried a different version'
if grep -Fxq helm:template "$TEST_EVENTS"; then fail 'rendered a chart after failed latest pull'; fi

for packages in missing multiple; do
    new_case "$packages-chart-packages"
    export TEST_PACKAGES=$packages
    run_installer "$input"
    assert_failed
    assert_no_mutation
    if grep -Fxq helm:template "$TEST_EVENTS"; then fail 'rendered an unverified chart package selection'; fi
done

new_case pinned-version-mismatch
export TEST_PACKAGES=mismatch
run_installer "$input" --version 0.0.1
assert_failed
assert_no_mutation
grep -Fq 'does not match the requested version' "$case_dir/output" || fail 'mismatched pinned chart was not explained'

new_case existing-namespace
run_installer "$input" --version 0.0.1
[[ $result == 0 ]] || fail 'default installation failed'
grep -Fq 'Connector installed successfully.' "$case_dir/output" || fail 'missing connected result'
grep -Fxq kubectl:namespace "$TEST_EVENTS" || fail 'namespace creation was not attempted when allowed'
grep -Fq 'helm pull oci://criticalmanufacturing.io/criticalmanufacturing/charts/saas-connector --version 0.0.1' "$TEST_ARGS" || fail 'incorrect customer chart or version'
grep -Fq 'helm upgrade --install saas-connector ' "$TEST_ARGS" || fail 'incorrect default release'
grep -Fq -- '--namespace connectivity' "$TEST_ARGS" || fail 'incorrect default namespace'
grep -Fq -- '--password-stdin' "$TEST_ARGS" || fail 'login did not use standard input'
grep -Fq -- 'criticalmanufacturing-registry' "$TEST_ARGS" || fail 'pull Secret was not configured'
assert_selected_package 0.0.1
assert_private_cleanup
# A retry must target the same release and namespace rather than add another one.
run_installer "$input" --version 0.0.1
[[ $result == 0 ]] || fail 'retry failed'
[[ $(grep -Fc 'helm upgrade --install saas-connector ' "$TEST_ARGS") == 2 ]] || fail 'retry changed the release'
[[ $(grep -Ec '^helm upgrade --install saas-connector .* --namespace connectivity --values ' "$TEST_ARGS") == 2 ]] || fail 'retry changed the namespace'
assert_private_cleanup

new_case missing-namespace
export TEST_NAMESPACE_EXISTS=no
run_installer "$input" --version 0.0.1 --namespace customer-ns --release customer-app
[[ $result == 0 ]] || fail 'installation into new namespace failed'
grep -Fxq kubectl:namespace "$TEST_EVENTS" || fail 'missing namespace was not created'
grep -Fq 'helm upgrade --install customer-app ' "$TEST_ARGS" || fail 'explicit release was ignored'
grep -Fq -- '--namespace customer-ns' "$TEST_ARGS" || fail 'explicit namespace was ignored'
[[ $(grep -Ev '^kubectl:(access|can-create-namespace)$' "$TEST_EVENTS") == $'helm:login\nhelm:pull\nhelm:template\nkubectl:namespace\nkubectl:secret\nkubectl:apply\nhelm:upgrade' ]] || fail 'installation operations were out of order'
assert_private_cleanup

new_case cancellation
run_installer n --version 0.0.1
assert_failed
assert_no_mutation
if grep -Eq '^helm:(login|pull|template)$' "$TEST_EVENTS"; then fail 'cancellation attempted authentication'; fi
grep -Fq 'Installation cancelled' "$case_dir/output" || fail 'cancellation was not explained'

for failure in login pull template; do
    new_case "$failure-failure"
    export TEST_FAILURE=$failure
    run_installer "$input" --version 0.0.1
    assert_failed
    assert_no_mutation
done

new_case install-failure
export TEST_FAILURE=upgrade
run_installer "$input" --version 0.0.1
assert_failed
python3 - "$case_dir/output" <<'PYTHON'
import sys

with open(sys.argv[1], encoding="utf-8") as result:
    output = result.read()
messages = ["Selected version: 0.0.1", "Validating the application settings...",
            "Preparing namespace connectivity and image access...",
            "Installing the connector and waiting for readiness (up to five minutes)...",
            "Readiness requires the connector to reach the configured application.",
            "kubectl get pods --namespace connectivity --context customer-cluster --selector app.kubernetes.io/instance=saas-connector",
            "Installation stopped while starting the connector"]
positions = [output.index(message) for message in messages]
assert positions == sorted(positions), "progress and failure instructions were out of order"
PYTHON


new_case namespace-scoped-access
export TEST_CREATE_NAMESPACE=no
run_installer "$input" --version 0.0.1
[[ $result == 0 ]] || fail 'namespace-scoped installation failed'
if grep -Fxq kubectl:namespace "$TEST_EVENTS"; then fail 'attempted namespace creation without permission'; fi
assert_private_cleanup

new_case namespace-failure
export TEST_FAILURE=namespace
run_installer "$input" --version 0.0.1
assert_failed
if grep -Eq '^(kubectl:(secret|apply)|helm:upgrade)$' "$TEST_EVENTS"; then fail 'ignored namespace creation error'; fi

new_case namespace-missing-without-create-permission
export TEST_CREATE_NAMESPACE=no TEST_NAMESPACE_EXISTS=no
run_installer "$input" --version 0.0.1
assert_failed
if grep -Fxq helm:upgrade "$TEST_EVENTS"; then fail 'installed into a missing namespace'; fi

new_case cluster-access-denied
export TEST_FAILURE=access
run_installer "$input" --version 0.0.1
assert_failed
assert_no_mutation
grep -Fq 'Ask your cluster administrator' "$case_dir/output" || fail 'missing cluster permission was not explained'

for failure in secret apply; do
    new_case "$failure-failure"
    export TEST_FAILURE=$failure
    run_installer "$input" --version 0.0.1
    assert_failed
    if grep -Fxq helm:upgrade "$TEST_EVENTS"; then fail 'installed without a valid image pull Secret'; fi
done

new_case no-terminal
export TEST_NO_TTY=yes
run_installer "$input" --version 0.0.1
assert_failed
assert_no_mutation
grep -Fq 'An interactive terminal is required.' "$case_dir/output" || fail 'missing terminal was not explained'
if grep -Eq '^helm:(login|pull|template)$' "$TEST_EVENTS"; then fail 'attempted registry access without a terminal'; fi

new_case missing-input
rm "$case_dir/work dir/link.yaml"
run_installer "$input" --version 0.0.1
assert_failed
assert_no_mutation
[[ ! -s $TEST_ARGS ]] || fail 'missing input was not rejected before invoking tools'

new_case missing-tool
mkdir "$case_dir/no-tools"
if (cd "$case_dir/work dir" && PATH="$case_dir/no-tools" "$bash_bin" "$installer" --version 0.0.1) >"$case_dir/output" 2>&1; then
    fail 'missing Helm was accepted'
fi
grep -Fq 'Install helm before running this installer.' "$case_dir/output" || fail 'missing tool was not explained'
assert_no_mutation

new_case unsupported-helm
export TEST_HELM_VERSION=v3.7.2
run_installer "$input" --version 0.0.1
assert_failed
assert_no_mutation
grep -Fq 'Helm 3.8 or newer is required.' "$case_dir/output" || fail 'old Helm was not rejected'

printf 'PASS: Helm installer latest stable selection, explicit version pinning, hidden registry override, authentication, validation before mutation, namespace permissions, retries, cancellation, failure handling, terminal prompts over piped input, credential privacy and cleanup\n'
