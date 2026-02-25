#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRECHECK_JSON="${ROOT_DIR}/.tmp/precheck-rust.json"
LATEST_RELEASE_JSON="${ROOT_DIR}/.tmp/latest-release.json"
LATEST_RELEASE_ASSET_JSON="${ROOT_DIR}/.tmp/latest-release-asset.json"

RUST_APP_ID="${RUST_APP_ID:-258550}"
RUST_DEPOT_ID="${RUST_DEPOT_ID:-258552}"
RUST_CHANNEL="${RUST_CHANNEL:-public}"
STEAMCMD_INFO_URL="${STEAMCMD_INFO_URL:-https://api.steamcmd.net/v1/info/${RUST_APP_ID}}"
GITHUB_REPO_SLUG="${GITHUB_REPOSITORY:-${GITHUB_REPO_SLUG:-}}"
GITHUB_API_BASE="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_RELEASE_LATEST_URL="${GITHUB_RELEASE_LATEST_URL:-${GITHUB_API_BASE}/repos/${GITHUB_REPO_SLUG}/releases/latest}"

mkdir -p "${ROOT_DIR}/.tmp"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required command: $bin" >&2
    exit 1
  }
done

GITHUB_JSON_HEADERS=(-H "Accept: application/vnd.github+json")
GITHUB_ASSET_HEADERS=(-H "Accept: application/octet-stream")
if [[ -n "${GH_TOKEN:-}" ]]; then
  GITHUB_JSON_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
  GITHUB_ASSET_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

PREV_BUILD_ID=""
PREV_BUILD_SOURCE=""
PREV_RELEASE_TAG=""

SHOULD_RUN="true"
REASON="no_previous_release"
BUILD_ID=""
MANIFEST_ID=""

if [[ -n "$GITHUB_REPO_SLUG" ]]; then
  RELEASE_HTTP_CODE="$(curl -sSL "${GITHUB_JSON_HEADERS[@]}" -o "$LATEST_RELEASE_JSON" -w '%{http_code}' "$GITHUB_RELEASE_LATEST_URL" || true)"
  if [[ "$RELEASE_HTTP_CODE" == "200" ]]; then
    PREV_RELEASE_TAG="$(jq -r '.tag_name // empty' "$LATEST_RELEASE_JSON")"
    PREV_ASSET_API_URL="$(jq -r '
      .assets // []
      | map(select(.name == "rust-versions-public.json"))
      | first
      | .url // empty
    ' "$LATEST_RELEASE_JSON")"

    if [[ -n "$PREV_ASSET_API_URL" ]] && curl -fsSL "${GITHUB_ASSET_HEADERS[@]}" "$PREV_ASSET_API_URL" -o "$LATEST_RELEASE_ASSET_JSON"; then
      PREV_BUILD_ID="$(jq -r '.rust.build_id // empty' "$LATEST_RELEASE_ASSET_JSON" 2>/dev/null || true)"
      if [[ -n "$PREV_BUILD_ID" ]]; then
        PREV_BUILD_SOURCE="release_asset_json"
      fi
    fi

    if [[ -z "$PREV_BUILD_ID" ]]; then
      PREV_BUILD_ID="$(jq -r '.body // ""' "$LATEST_RELEASE_JSON" \
        | grep -Eo '(^|[[:space:]])build_id=[0-9]+' \
        | grep -Eo '[0-9]+' \
        | head -n1 || true)"
      if [[ -n "$PREV_BUILD_ID" ]]; then
        PREV_BUILD_SOURCE="release_body_machine"
      fi
    fi

    if [[ -z "$PREV_BUILD_ID" ]]; then
      PREV_BUILD_ID="$(jq -r '.body // ""' "$LATEST_RELEASE_JSON" \
        | grep -Eo 'Rust build_id \(web pre-check\):[[:space:]]*[0-9]+' \
        | grep -Eo '[0-9]+' \
        | head -n1 || true)"
      if [[ -n "$PREV_BUILD_ID" ]]; then
        PREV_BUILD_SOURCE="release_body_human"
      fi
    fi

    if [[ -z "$PREV_BUILD_ID" ]]; then
      PREV_BUILD_ID="$(jq -r '.tag_name // ""' "$LATEST_RELEASE_JSON" \
        | sed -n 's/.*-b\([0-9][0-9]*\)-.*/\1/p' \
        | head -n1 || true)"
      if [[ -n "$PREV_BUILD_ID" ]]; then
        PREV_BUILD_SOURCE="release_tag"
      fi
    fi
  elif [[ "$RELEASE_HTTP_CODE" == "404" ]]; then
    REASON="no_previous_release"
  else
    REASON="release_lookup_failed"
  fi
else
  REASON="no_github_repository"
fi

if curl -fsSL --compressed "$STEAMCMD_INFO_URL" -o "$PRECHECK_JSON"; then
  BUILD_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$RUST_CHANNEL" '.data[$app].depots[$depot].manifests[$branch].download // empty' "$PRECHECK_JSON")"
  MANIFEST_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$RUST_CHANNEL" '.data[$app].depots[$depot].manifests[$branch].gid // empty' "$PRECHECK_JSON")"

  if [[ -z "$BUILD_ID" ]]; then
    SHOULD_RUN="true"
    REASON="precheck_missing_build_id"
  elif [[ -n "$PREV_BUILD_ID" && "$BUILD_ID" == "$PREV_BUILD_ID" ]]; then
    SHOULD_RUN="false"
    REASON="same_build_release"
  else
    SHOULD_RUN="true"
    if [[ -n "$PREV_BUILD_ID" ]]; then
      REASON="new_build_release"
    fi
  fi
else
  SHOULD_RUN="true"
  REASON="precheck_fetch_failed"
fi

echo "Precheck result: should_run=${SHOULD_RUN}, reason=${REASON}, build_id=${BUILD_ID:-n/a}, prev_build_id=${PREV_BUILD_ID:-n/a}, prev_source=${PREV_BUILD_SOURCE:-n/a}, prev_release_tag=${PREV_RELEASE_TAG:-n/a}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "should_run=${SHOULD_RUN}"
    echo "reason=${REASON}"
    echo "build_id=${BUILD_ID}"
    echo "manifest_id=${MANIFEST_ID}"
    echo "prev_build_id=${PREV_BUILD_ID}"
    echo "prev_build_source=${PREV_BUILD_SOURCE}"
    echo "prev_release_tag=${PREV_RELEASE_TAG}"
  } >> "$GITHUB_OUTPUT"
fi
