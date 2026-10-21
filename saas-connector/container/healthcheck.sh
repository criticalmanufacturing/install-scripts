#!/usr/bin/env bash
set -euo pipefail
# Check the local IPv4 listener without opening an unauthenticated TLS connection.
# TCP-connect probes would emit router framing errors on every health check.
# 0100007F:1627 is 127.0.0.1:5671 in Linux's socket table; 0A means LISTEN.
listening=0
while read -r _ endpoint _ state _; do
    if [[ $endpoint == 0100007F:1627 && $state == 0A ]]; then
        listening=1
        break
    fi
done </proc/net/tcp
((listening))
if [[ ${1:-live} == ready ]]; then
    # The child Bash expands its positional arguments.
    # shellcheck disable=SC2016
    timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${APP_IP:?APP_IP is required}" "${APP_PORT:?APP_PORT is required}"
fi
