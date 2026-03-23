#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-FileCopyrightText: 2018 GitHub, Inc. and contributors
# SPDX-License-Identifier: Apache-2.0

set -e          # exit immediately if a command fails
set -E          # inherit ERR traps in subshells and functions
set -o pipefail # fail pipelines when any command fails
set -u          # treat unset variables as an error and exit

# Temporary workdir for the script
TMPDIR="$(mktemp -d --suffix .cachix-push)"

# Expected arguments and their defaults if not passed in environment variables
CACHIX_AUTH_TOKEN_FILE="${CACHIX_AUTH_TOKEN_FILE:=/dev/null}"
CACHIX_CACHE_NAME="${CACHIX_CACHE_NAME:=ghaf-dev}"
CACHIX_STATE_DIR="${CACHIX_STATE_DIR:=/var/lib/cachix-push}"
RETRY_FILE_MAX_ENTRIES="${RETRY_FILE_MAX_ENTRIES:=500}"
# Persistent state files survive service restarts so we do not lose the
# baseline snapshot or the retry queue.
REF_FILE="$CACHIX_STATE_DIR/ref"
RETRY_FILE="$CACHIX_STATE_DIR/retry"
CURRENT_CACHIX_TOKEN_DIGEST=""

# Lists all nix store paths potentially pushed to cachix
list_nix_store_paths() {
  out=$1
  tmp="$(mktemp --tmpdir="$(dirname "$out")" ".$(basename "$out").XXXXXX")"
  # https://github.com/cachix/cachix-action/blob/ee79d/dist/list-nix-store.sh
  find /nix/store -mindepth 1 -maxdepth 1 \
    ! -name '*.drv' \
    ! -name '*.drv.chroot' \
    ! -name '*.check' \
    ! -name '*.lock' \
    ! -name '*.links' \
    -print | LC_ALL=C sort >"$tmp"
  mv -f "$tmp" "$out"
}

# Return success for store paths that should never be uploaded, either because
# the path itself matches the exclusion patterns or because it contains one of
# the filtered image artifacts inside a shallow directory tree.
should_filter_store_path() {
  storepath=$1
  filter='(nixos\.img$|\.iso$|\.raw\.zst|\.img\.zst|\-disko-images|\-set-environment$|\-etc-pam-environment$)'

  if [[ $storepath =~ $filter ]]; then
    return 0
  fi

  # Skip directory trees that contain filtered artifacts.
  if [ -d "$storepath" ] || [ -L "$storepath" ]; then
    if find -L "$storepath" -maxdepth 2 2>/dev/null | grep -qP "$filter"; then
      return 0
    fi
  fi

  return 1
}

# Combine the persisted retry queue with newly discovered store paths while
# preserving retry-first order and removing duplicates.
merge_candidates() {
  retry_file=$1
  new_file=$2
  candidates=$3

  : >"$candidates"
  # Bash associative arrays require bash 4+, which is fine on NixOS.
  # Keep retry entries first so previously failed pushes are retried before
  # newly discovered store paths.
  declare -A seen=()

  while read -r storepath; do
    [ -n "$storepath" ] || continue

    if [ -n "${seen["$storepath"]+x}" ]; then
      continue
    fi

    seen["$storepath"]=1
    echo "$storepath" >>"$candidates"
  done < <(cat "$retry_file" "$new_file")
}

# Walk the combined candidate list once, filtering unsupported paths and
# re-queueing only the paths whose cachix upload attempt failed.
process_candidates() {
  candidates=$1
  retry_next=$2

  : >"$retry_next"

  while read -r storepath; do
    [ -n "$storepath" ] || continue

    if [ ! -e "$storepath" ]; then
      echo "[!] Skip vanished store path: $storepath"
      continue
    fi

    if should_filter_store_path "$storepath"; then
      echo "[+] Skip filtered store path: $storepath"
      continue
    fi

    push_log="$TMPDIR/cachix-push.log"
    if ! cachix push -j4 -l16 "$CACHIX_CACHE_NAME" "$storepath" >"$push_log" 2>&1; then
      cat "$push_log" >&2
      echo "[!] Failed to push store path, will retry: $storepath" >&2
      echo "$storepath" >>"$retry_next"
      continue
    fi

    # Suppress the noisy per-path no-op message. Actual uploads still emit the
    # detailed cachix output so successful pushes remain visible in the journal.
    if ! grep -qxF 'Nothing to push - all store paths are already on Cachix.' "$push_log"; then
      cat "$push_log"
    fi
  done <"$candidates"
}

# Reconfigure cachix when the token file changes. Startup failures are fatal,
# but runtime refresh failures are left retryable so the service can keep
# running and pick up a repaired secret on a later poll.
refresh_cachix_auth_token() {
  strict_mode=$1

  if [ ! -r "$CACHIX_AUTH_TOKEN_FILE" ] || [ ! -s "$CACHIX_AUTH_TOKEN_FILE" ]; then
    echo "[!] Missing or empty CACHIX_AUTH_TOKEN_FILE: $CACHIX_AUTH_TOKEN_FILE" >&2
    if [ "$strict_mode" = "strict" ]; then
      exit 10
    fi
    return 1
  fi

  token_digest="$(sha256sum "$CACHIX_AUTH_TOKEN_FILE" | cut -d' ' -f1)"
  if [ "$token_digest" = "$CURRENT_CACHIX_TOKEN_DIGEST" ]; then
    return 0
  fi

  if ! cachix authtoken --stdin <"$CACHIX_AUTH_TOKEN_FILE"; then
    echo "[!] Failed to configure cachix auth token" >&2
    if [ "$strict_mode" = "strict" ]; then
      exit 11
    fi
    return 1
  fi

  CURRENT_CACHIX_TOKEN_DIGEST="$token_digest"
  echo "[+] Refreshed cachix auth token"
}

# Remove TMPDIR on exit
on_exit() {
  echo "[+] Stop (TMPDIR:$TMPDIR)"
  rm -fr "$TMPDIR"
}
trap on_exit EXIT

echo "[+] Start (TMPDIR=$TMPDIR)"

# Set cachix authentication token
mkdir -p "$CACHIX_STATE_DIR"
touch "$RETRY_FILE"
refresh_cachix_auth_token strict

# Initialize the persistent reference only once. This avoids losing queued
# paths across service restarts while still starting from the current store on
# first boot.
if [ ! -e "$REF_FILE" ]; then
  list_nix_store_paths "$REF_FILE"
  echo "[+] Initialized persistent reference"
fi

# Poll new store paths every 30 seconds
while sleep 30; do
  refresh_cachix_auth_token best-effort || true

  # Snapshot nix store paths for the current poll iteration
  list_nix_store_paths "$TMPDIR/snapshot"
  # Both files are sorted with LC_ALL=C, so comm can reliably emit only the
  # store paths that were added since the last reference snapshot.
  LC_ALL=C comm -13 "$REF_FILE" "$TMPDIR/snapshot" >"$TMPDIR/new"

  merge_candidates "$RETRY_FILE" "$TMPDIR/new" "$TMPDIR/candidates"

  process_candidates "$TMPDIR/candidates" "$TMPDIR/retry-next"

  if [ "$RETRY_FILE_MAX_ENTRIES" -gt 0 ]; then
    # Keep the most recently failed entries if the retry queue needs pruning.
    tail -n "$RETRY_FILE_MAX_ENTRIES" "$TMPDIR/retry-next" >"$TMPDIR/retry-pruned"
    mv -f "$TMPDIR/retry-pruned" "$RETRY_FILE"
  else
    mv -f "$TMPDIR/retry-next" "$RETRY_FILE"
  fi

  # Always advance the reference after persisting retries. Paths that still
  # need uploading remain in RETRY_FILE; advancing REF_FILE prevents the same
  # "new" paths from being rediscovered and duplicated on every poll.
  cp -f "$TMPDIR/snapshot" "$TMPDIR/ref-update"
  mv -f "$TMPDIR/ref-update" "$REF_FILE"
done
