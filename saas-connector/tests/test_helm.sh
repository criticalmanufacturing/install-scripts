#!/usr/bin/env bash
set -Eeuo pipefail
chart=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../helm/saas-connector" && pwd)
test_dir=$(mktemp -d)
trap 'find "$test_dir" -type f -delete; find "$test_dir" -depth -type d -empty -delete' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat >"$test_dir/link.yaml" <<'YAML'
apiVersion: skupper.io/v2alpha1
kind: Link
metadata:
  name: cloud
spec:
  endpoints:
    - host: cloud.example.com
      port: "443"
      name: inter-router
  tlsCredentials: test-tls
---
apiVersion: v1
kind: Secret
metadata:
  name: test-tls
data:
  host: unrelated.example.com
YAML
options=(--namespace connectivity --set connectorName=another-app --set appIp=192.168.1.13 \
    --set appPort=7990 --set image.tag=test --set-file "linkYaml=$test_dir/link.yaml")
helm lint "$chart" "${options[@]}"
helm template app-one "$chart" "${options[@]}" >"$test_dir/default.yaml"
helm template app-two "$chart" "${options[@]}" --set cloudIp=63.187.234.201 >"$test_dir/override.yaml"
for item in 'runAsNonRoot: true' 'readOnlyRootFilesystem: true' 'allowPrivilegeEscalation: false' \
    'drop: [ALL]' 'type: RuntimeDefault' 'automountServiceAccountToken: false' 'type: Recreate'; do
    grep -Fq "$item" "$test_dir/default.yaml" || fail "missing security/default setting: $item"
done
if grep -Eq 'runAsUser:|runAsGroup:|fsGroup:|hostPath:|hostNetwork:|kind: (ClusterRole|Role|Site|Connector)|privileged: true' "$test_dir/default.yaml"; then
    fail 'chart depends on fixed IDs, host access or Skupper CRDs'
fi
if grep -q 'hostAliases:' "$test_dir/default.yaml"; then fail 'DNS mode creates a hosts override'; fi
grep -q 'hostAliases:' "$test_dir/override.yaml" || fail 'missing hosts override'
grep -q '"cloud.example.com"' "$test_dir/override.yaml" || fail 'hostname inference'
grep -q '"63.187.234.201"' "$test_dir/override.yaml" || fail 'IP override'
grep -q 'name: app-one-link' "$test_dir/default.yaml" || fail 'first release Secret'
grep -q 'name: app-two-link' "$test_dir/override.yaml" || fail 'second release Secret'
# Changes to credentials must roll out a pod with a different checksum.
printf '\n# rotated fixture\n' >>"$test_dir/link.yaml"
helm template app-one "$chart" "${options[@]}" >"$test_dir/rotated.yaml"
[[ $(sed -n '/checksum\/link:/p' "$test_dir/default.yaml") != "$(sed -n '/checksum\/link:/p' "$test_dir/rotated.yaml")" ]] || fail 'credential change did not change pod checksum'
for option in connectorName= appIp= appPort=0 appPort=65536 image.tag= timeout=0 cloudIp=invalid; do
    if helm template invalid "$chart" "${options[@]}" --set "$option" >"$test_dir/error" 2>&1; then fail "invalid input accepted: $option"; fi
done
if helm template invalid "$chart" "${options[@]}" --set-file linkYaml=/dev/null >"$test_dir/error" 2>&1; then fail 'empty link accepted'; fi
printf 'PASS: Helm schema, release isolation, hosts mapping, credential rollout and restricted pod settings\n'
