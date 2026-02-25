#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${ROOT_DIR}/data/rust-versions-public.json"
PRECHECK_JSON="${ROOT_DIR}/.tmp/precheck-rust.json"

RUST_APP_ID="${RUST_APP_ID:-258550}"
RUST_DEPOT_ID="${RUST_DEPOT_ID:-258552}"
RUST_CHANNEL="${RUST_CHANNEL:-public}"
STEAMCMD_INFO_URL="${STEAMCMD_INFO_URL:-https://api.steamcmd.net/v1/info/${RUST_APP_ID}}"

mkdir -p "${ROOT_DIR}/.tmp"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required command: $bin" >&2
    exit 1
  }
done

PREV_BUILD_ID=""
if [[ -f "$OUT_JSON" ]]; then
  PREV_BUILD_ID="$(jq -r '.rust.build_id // empty' "$OUT_JSON" 2>/dev/null || true)"
fi

SHOULD_RUN="true"
REASON="no_previous_json"
BUILD_ID=""
MANIFEST_ID=""

if curl -fsSL --compressed "$STEAMCMD_INFO_URL" -o "$PRECHECK_JSON"; then
  BUILD_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$RUST_CHANNEL" '.data[$app].depots[$depot].manifests[$branch].download // empty' "$PRECHECK_JSON")"
  MANIFEST_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$RUST_CHANNEL" '.data[$app].depots[$depot].manifests[$branch].gid // empty' "$PRECHECK_JSON")"

  if [[ -z "$BUILD_ID" ]]; then
    SHOULD_RUN="true"
    REASON="precheck_missing_build_id"
  elif [[ -n "$PREV_BUILD_ID" && "$BUILD_ID" == "$PREV_BUILD_ID" ]]; then
    SHOULD_RUN="false"
    REASON="same_build"
  else
    SHOULD_RUN="true"
    REASON="new_build"
  fi
else
  SHOULD_RUN="true"
  REASON="precheck_fetch_failed"
fi

echo "Precheck result: should_run=${SHOULD_RUN}, reason=${REASON}, build_id=${BUILD_ID:-n/a}, prev_build_id=${PREV_BUILD_ID:-n/a}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "should_run=${SHOULD_RUN}"
    echo "reason=${REASON}"
    echo "build_id=${BUILD_ID}"
    echo "manifest_id=${MANIFEST_ID}"
    echo "prev_build_id=${PREV_BUILD_ID}"
  } >> "$GITHUB_OUTPUT"
fi
