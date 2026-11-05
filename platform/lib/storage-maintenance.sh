#!/usr/bin/env bash
# Explicit expansion with recovery manifests prepared by the Kubernetes CLI.
#
# Expected globals, initialized by the installer before calling these functions:
#   DRY_RUN       Skip cluster changes when true.
#   RESIZE_PLAN   component|statefulset|template|new-size|old-size entries to apply.
#   VALUES_FILES  Ordered values files passed to Helm.
#   HELM          Helm command to invoke.
#   CHARTS_DIR    Directory containing the component charts.
#   NAMESPACE     Namespace containing the releases and volumes.
#   OUTPUT_DIR    Parent directory for private recovery manifests and logs.
#   HELM_TIMEOUT  Timeout for each affected release upgrade.
# Shared helper calls use the additional state documented in install-common.sh.

# storage_maintenance_worker: preflight planned expansions, save recovery manifests and upgrade affected releases.
storage_maintenance_worker() (
  # Subshell confines recovery traps and umask to this explicit operation.
  if $DRY_RUN; then info "Storage maintenance dry run: no volumes or controllers changed."; return 0; fi
  if ((${#RESIZE_PLAN[@]} == 0)); then info "No volume expansion is needed."; return 0; fi
  local -a vargs=() comps=() controllers=()
  local -A seen=() saved=()
  local f line comp sts vct size old rel directory
  for f in "${VALUES_FILES[@]}"; do vargs+=(-f "$f"); done
  for line in "${RESIZE_PLAN[@]}"; do
    IFS='|' read -r comp sts vct size old <<<"$line"
    if [[ -z "${seen[$comp]+set}" ]]; then comps+=("$comp"); seen[$comp]=1; fi
    if [[ -z "${saved[$sts]+set}" ]]; then controllers+=("$sts"); saved[$sts]=1; fi
  done
  info "This expands PVCs, temporarily orphans their pods and upgrades only the affected releases."
  info "On failure, restore missing controllers from the saved YAML as documented. Expanded PVCs cannot shrink."
  info "Run without other installers or storage maintenance acting on these releases."
  umask 077
  mkdir -p "$OUTPUT_DIR/storage-maintenance"
  directory=$(mktemp -d "$OUTPUT_DIR/storage-maintenance/run-XXXXXXXX")
  info "Private recovery directory: $directory"
  # Render against live cluster state for EVERY affected release before the first mutation.
  # In particular, lookup-based retained Kafka identity checks must pass first.
  for comp in "${comps[@]}"; do
    rel="$(release_name "$comp")"
    if ! "$HELM" upgrade "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" "${vargs[@]}" \
      --dry-run=server >"$directory/preflight-$rel.log" 2>&1; then
      err "Server-side Helm preflight failed for $rel; nothing was changed."
      err "See $directory/preflight-$rel.log. Maintenance requires Helm 3.13+ or Helm 4."
      exit 1
    fi
  done
  for sts in "${controllers[@]}"; do
    kcn get statefulset "$sts" -o json >"$directory/live-$sts.json" || exit 1
    # Use the Kubernetes CLI's local JSON merge support; no cluster mutation here.
    kc patch --local -f "$directory/live-$sts.json" --type=merge \
      -p '{"metadata":{"uid":null,"resourceVersion":null,"generation":null,"creationTimestamp":null,"managedFields":null,"selfLink":null,"deletionTimestamp":null,"deletionGracePeriodSeconds":null},"status":null}' \
      -o yaml >"$directory/statefulset-$sts.yaml" || exit 1
  done
  # Also covers SIGINT/SIGTERM after a controller has been removed.
  trap 'rc=$?; if ((rc)); then err "Maintenance interrupted/failed. PVC expansion is retained; check for missing StatefulSet controllers."; err "Restore missing controllers with kubectl/oc create -f <saved YAML>; see the README."; err "Recovery files: $directory"; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for comp in "${comps[@]}"; do
    apply_resize "$comp"
    rel="$(release_name "$comp")"
    if ! "$HELM" upgrade "$rel" "$CHARTS_DIR/$comp" -n "$NAMESPACE" "${vargs[@]}" \
      --wait --timeout "$HELM_TIMEOUT" >"$directory/upgrade-$rel.log" 2>&1; then
      err "Helm upgrade failed for $rel. See $directory/upgrade-$rel.log."
      exit 1
    fi
  done
  ok "Storage maintenance completed. Recovery snapshots remain in $directory."
)

# cancel_storage_maintenance <status> <worker-pid> <previous-background-pid>: stop the worker group and exit.
cancel_storage_maintenance() {
  local status=$1 child=$2 previous=$3
  # $! covers cancellation after fork but before the parent records the worker PID.
  # Before the fork, it still refers to an unrelated, previously started job.
  if [[ -n "$child" && "$child" != "$previous" ]]; then
    kill -TERM -- -"$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    wait "$child" || true
  fi
  exit "$status"
}

# run_storage_maintenance: confirm and run planned storage expansion, forwarding interrupts to the worker.
run_storage_maintenance() {
  if $DRY_RUN; then info "Storage maintenance dry run: no volumes or controllers changed."; return 0; fi
  if ((${#RESIZE_PLAN[@]} == 0)); then info "No volume expansion is needed."; return 0; fi
  confirm_or_exit "Start storage maintenance in $NAMESPACE?"
  local maintenance_pid="" previous_background_pid=${!:-} saved_traps had_monitor=false rc=0
  saved_traps=$(trap -p INT TERM)
  trap 'cancel_storage_maintenance 143 "${maintenance_pid:-${!:-}}" "$previous_background_pid"' TERM
  trap 'cancel_storage_maintenance 130 "${maintenance_pid:-${!:-}}" "$previous_background_pid"' INT
  [[ $- != *m* ]] || had_monitor=true
  # A separate process group allows signals to stop Helm/kubectl as well as the worker.
  # All interactive confirmation happens above, in the foreground installer.
  set -m
  storage_maintenance_worker &
  maintenance_pid=$!
  $had_monitor || set +m
  wait "$maintenance_pid" || rc=$?
  trap - INT TERM
  [[ -z "$saved_traps" ]] || eval "$saved_traps"
  return "$rc"
}
