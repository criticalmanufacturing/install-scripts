#!/usr/bin/env bash
# Real, disposable Docker test. No production links, credentials, or cloud endpoints.
set -Eeuo pipefail
image=${SAAS_CONNECTOR_TEST_IMAGE:-saas-connector:dev}
prefix="saas-connector-test-$$-$RANDOM"
cloud="$prefix-cloud" backend="$prefix-backend" connector="$prefix-connector" second="$prefix-second"
network="$prefix-network" cloud_state="$prefix-cloud-state" app_state="$prefix-app-state" link_volume="$prefix-link"
test_dir=$(mktemp -d)
cleanup() {
    local result=$?
    if ((result)); then
        for container in "$cloud" "$connector" "$second"; do docker logs --tail 40 "$container" 2>/dev/null || true; done
    fi
    docker container rm -f "$cloud" "$connector" "$second" "$backend" >/dev/null 2>&1 || true
    docker volume rm "$cloud_state" "$app_state" "$link_volume" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    find "$test_dir" -type f -delete
    rmdir "$test_dir"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
restricted=(--read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs '/tmp:rw,mode=1777' --memory 512m)

docker run --rm "${restricted[@]}" --user 1000710001:0 "$image" --version >"$test_dir/version"
grep -q '^2.2.3$' "$test_dir/version" || fail 'wrong CLI version'
grep -q '3.5.3' "$test_dir/version" || fail 'wrong router version'
docker run --rm "${restricted[@]}" --entrypoint skupper "$image" --platform kubernetes --help >"$test_dir/platform-help"
grep -q -- --kubeconfig "$test_dir/platform-help" || fail 'explicit CLI platform override'
docker run --rm --entrypoint /bin/bash "$image" -c \
    '! command -v podman; ! command -v docker; ! command -v systemctl; ! command -v sudo'
docker network create "$network" >/dev/null
for volume in "$cloud_state" "$app_state" "$link_volume"; do docker volume create "$volume" >/dev/null; done

# A disposable HTTP backend; no testing tools are added to the connector image.
docker run -d --name "$backend" --network "$network" --network-alias backend \
    "${restricted[@]}" --user 1000710001:0 --entrypoint /bin/sh busybox:1.37.0 -c '
    mkdir -p /tmp/www
    printf "saas-connector\n" > /tmp/www/index.html
    exec httpd -f -p 7990 -h /tmp/www
' >/dev/null

# A cloud-equivalent site: native Linux CLI, generated client credentials, two listeners.
docker run -d --name "$cloud" --hostname cloud.test --network "$network" --network-alias cloud.test \
    "${restricted[@]}" --user 10001:0 -v "$cloud_state:/output" --entrypoint /bin/bash "$image" -c '
    set -Eeuo pipefail
    umask 077
    export HOME=/output/home
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    config=/output/namespaces/default/runtime/router/skrouterd.json
    if [[ ! -s $config ]]; then
        skupper --platform linux site create test-cloud --enable-link-access
        skupper --platform linux listener create another-app 8080 --host 0.0.0.0
        skupper --platform linux listener create second-app 8081 --host 0.0.0.0
        skupper --platform linux system start
        skupper --platform linux link generate --host cloud.test > /output/link.yaml
    fi
    exec skrouterd -c "$config"
' >/dev/null
for ((attempt=0; attempt<60; attempt++)); do
    if docker exec "$cloud" test -s /output/link.yaml; then break; fi
    sleep 1
done
docker exec "$cloud" cat /output/link.yaml >"$test_dir/link.yaml"
[[ -s $test_dir/link.yaml ]] || fail 'cloud link generation'
# Copy synthetic credentials through stdin; this also works with a remote Docker daemon.
docker run --rm -i --user 0 -v "$link_volume:/input" --entrypoint /bin/bash "$image" \
    -c 'cat > /input/link.yaml; chmod 444 /input/link.yaml' <"$test_dir/link.yaml"

docker run -d --name "$connector" --network "$network" "${restricted[@]}" --user 1000710001:0 \
    -v "$app_state:/output" -v "$link_volume:/input:ro" \
    -e SITE_NAME=test-connector -e NAMESPACE=connectivity -e CONNECTOR_NAME=another-app -e APP_IP=backend -e APP_PORT=7990 \
    "$image" >/dev/null

request() {
    docker exec "$cloud" timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"; printf "GET / HTTP/1.0\r\n\r\n" >&3; cat <&3' _ "$1" 2>/dev/null
}
wait_traffic() {
    local port=$1
    for ((attempt=0; attempt<60; attempt++)); do
        if request "$port" | grep -q saas-connector; then return; fi
        sleep 1
    done
    fail "no authenticated inter-site application traffic on port $port"
}
wait_traffic 8080
docker exec "$connector" skupper link status >"$test_dir/link-status"
docker exec "$connector" skupper --namespace connectivity link status >"$test_dir/explicit-link-status"
cmp -s "$test_dir/link-status" "$test_dir/explicit-link-status" || fail 'CLI namespace default'
grep -q '"connectionStatus": "SUCCESS"' "$test_dir/link-status" || fail 'live link status must show the authenticated connection'
if docker exec "$connector" skupper link status --namespace >"$test_dir/invalid-status" 2>&1; then fail 'missing namespace value accepted'; fi
for flag in --namespace -n; do
    docker exec -e NAMESPACE=unused "$cloud" skupper "$flag" default site status >"$test_dir/override-status"
    grep -q test-cloud "$test_dir/override-status" || fail 'explicit CLI namespace override'
done
printf 'PASS: plain skupper link status uses the container namespace; explicit flags override it\n'
docker exec "$connector" healthcheck.sh ready
if docker logs "$connector" 2>&1 | grep -q 'No protocol header found'; then fail 'health probes caused router TLS errors'; fi
docker exec "$connector" bash -c '[[ $(id -u) == 1000710001 && ! -w /usr/local/bin && -r /input/link.yaml && ! -w /input/link.yaml ]]'
printf 'PASS: native Linux router, arbitrary UID, read-only filesystem, mTLS link and HTTP traffic\n'

# A container restart retains its emptyDir-equivalent state, which must be rebuilt.
docker restart --time 10 "$connector" >/dev/null
wait_traffic 8080
printf 'PASS: connector restart with existing generated state\n'

# Separate releases can reuse a link and have independent connector names and sites.
docker run -d --name "$second" --network "$network" "${restricted[@]}" --user 1000710002:0 \
    --tmpfs /output:rw,mode=1777 -v "$link_volume:/input:ro" \
    -e SITE_NAME=second-site -e CONNECTOR_NAME=second-app -e APP_IP=backend -e APP_PORT=7990 \
    "$image" >/dev/null
wait_traffic 8081
wait_traffic 8080
printf 'PASS: two applications in independent sites using the same cloud link\n'

# Network outages must not kill a healthy router; reconnect after the cloud returns.
docker stop --time 10 "$cloud" >/dev/null
docker exec "$connector" healthcheck.sh live
for ((attempt=0; attempt<15; attempt++)); do
    docker exec "$connector" skupper link status >"$test_dir/link-down"
    if ! grep -q '"connectionStatus": "SUCCESS"' "$test_dir/link-down"; then break; fi
    sleep 1
done
grep -Eq '"connectionStatus": "(FAILED|CONNECTING)"' "$test_dir/link-down" || fail 'live link status did not detect the cloud outage'
docker start "$cloud" >/dev/null
wait_traffic 8080
wait_traffic 8081
docker exec "$connector" skupper link status >"$test_dir/link-restored"
grep -q '"connectionStatus": "SUCCESS"' "$test_dir/link-restored" || fail 'live link status did not recover'
printf 'PASS: cloud outage and authenticated reconnection\n'

docker stop --time 10 "$backend" >/dev/null
if docker exec "$connector" healthcheck.sh ready; then fail 'readiness accepted an unavailable backend'; fi
docker exec "$connector" healthcheck.sh live
docker start "$backend" >/dev/null
wait_traffic 8080
printf 'PASS: backend outage affects readiness without stopping the router\n'

docker stop --time 10 "$connector" >/dev/null
[[ $(docker inspect -f '{{.State.ExitCode}}' "$connector") == 0 ]] || fail 'router did not terminate gracefully'
printf 'PASS: graceful SIGTERM shutdown\n'
