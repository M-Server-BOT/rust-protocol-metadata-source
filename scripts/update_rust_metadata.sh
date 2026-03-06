#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp/rust-metadata"
TOOLS_DIR="${ROOT_DIR}/.tools/depotdownloader"
OUT_JSON="${TMP_DIR}/rust-versions-public.json"
CANDIDATE_JSON="${TMP_DIR}/candidate.json"
PROBE_JSON="${TMP_DIR}/protocol.json"
LATEST_RELEASE_JSON="${TMP_DIR}/latest-release.json"
PREV_RELEASE_JSON="${TMP_DIR}/prev-release.json"
RELEASE_NOTES="${TMP_DIR}/release-notes.txt"
FILELIST="${TMP_DIR}/filelist.txt"
DOWNLOAD_DIR="${TMP_DIR}/depot"
PRECHECK_JSON="${TMP_DIR}/precheck.json"

CHANNEL="${RUST_CHANNEL:-public}"
RUST_APP_ID="${RUST_APP_ID:-258550}"
RUST_DEPOT_ID="${RUST_DEPOT_ID:-258552}"
STEAMCMD_INFO_URL="${STEAMCMD_INFO_URL:-https://api.steamcmd.net/v1/info/${RUST_APP_ID}}"
GITHUB_REPO_SLUG="${GITHUB_REPOSITORY:-${GITHUB_REPO_SLUG:-}}"
GITHUB_API_BASE="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_RELEASE_LATEST_URL="${GITHUB_RELEASE_LATEST_URL:-${GITHUB_API_BASE}/repos/${GITHUB_REPO_SLUG}/releases/latest}"

mkdir -p "$TMP_DIR" "$TOOLS_DIR"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_bin curl
require_bin jq
require_bin unzip
require_bin dotnet
require_bin gh

GITHUB_JSON_HEADERS=(-H "Accept: application/vnd.github+json")
GITHUB_ASSET_HEADERS=(-H "Accept: application/octet-stream")
if [[ -n "${GH_TOKEN:-}" ]]; then
  GITHUB_JSON_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
  GITHUB_ASSET_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

PREV_BUILD_ID=""
PREV_PROTOCOL_NETWORK=""
PREV_PROTOCOL_PRINTABLE=""

if [[ -n "$GITHUB_REPO_SLUG" ]]; then
  RELEASE_HTTP_CODE="$(curl -sSL "${GITHUB_JSON_HEADERS[@]}" -o "$LATEST_RELEASE_JSON" -w '%{http_code}' "$GITHUB_RELEASE_LATEST_URL" || true)"
  if [[ "$RELEASE_HTTP_CODE" == "200" ]]; then
    PREV_ASSET_API_URL="$(jq -r '
      .assets // []
      | map(select(.name == "rust-versions-public.json"))
      | first
      | .url // empty
    ' "$LATEST_RELEASE_JSON")"

    if [[ -n "$PREV_ASSET_API_URL" ]] && curl -fsSL "${GITHUB_ASSET_HEADERS[@]}" "$PREV_ASSET_API_URL" -o "$PREV_RELEASE_JSON"; then
      PREV_BUILD_ID="$(jq -r '.rust.build_id // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_PROTOCOL_NETWORK="$(jq -r '.rust.protocol.network // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_PROTOCOL_PRINTABLE="$(jq -r '.rust.protocol.printable // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
    fi
  fi
fi

if ! curl -fsSL --compressed "$STEAMCMD_INFO_URL" -o "$PRECHECK_JSON"; then
  echo "Failed to fetch pre-check metadata from api.steamcmd.net." >&2
  exit 1
fi

BUILD_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$CHANNEL" '.data[$app].depots[$depot].manifests[$branch].download // empty' "$PRECHECK_JSON")"
MANIFEST_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$CHANNEL" '.data[$app].depots[$depot].manifests[$branch].gid // empty' "$PRECHECK_JSON")"

if [[ -z "$BUILD_ID" ]]; then
  echo "api.steamcmd.net response did not contain build_id for depot ${RUST_DEPOT_ID} branch ${CHANNEL}." >&2
  exit 1
fi

RUST_GLOBAL_DLL=""
if [[ "$BUILD_ID" == "$PREV_BUILD_ID" && ( -n "$PREV_PROTOCOL_NETWORK" || -n "$PREV_PROTOCOL_PRINTABLE" ) ]]; then
  jq -n \
    --argjson network "${PREV_PROTOCOL_NETWORK:-null}" \
    --arg printable "$PREV_PROTOCOL_PRINTABLE" \
    '{
      protocol: {
        network: $network,
        printable: (if $printable == "" then null else $printable end)
      }
    }' >"$PROBE_JSON"
else
  DEPOT_RELEASE_JSON="$(gh api repos/SteamRE/DepotDownloader/releases/latest)"
  DEPOT_ASSET_URL="$(jq -r '
    .assets[]
    | select(.name | test("linux(-x64)?\\.zip$"; "i"))
    | .browser_download_url
  ' <<<"$DEPOT_RELEASE_JSON" | head -n1)"

  if [[ -z "$DEPOT_ASSET_URL" || "$DEPOT_ASSET_URL" == "null" ]]; then
    echo "Could not find a Linux DepotDownloader asset in latest release." >&2
    exit 1
  fi

  curl -fsSL "$DEPOT_ASSET_URL" -o "${TMP_DIR}/depotdownloader.zip"
  rm -rf "$TOOLS_DIR"/*
  unzip -q -o "${TMP_DIR}/depotdownloader.zip" -d "$TOOLS_DIR"
  chmod +x "$TOOLS_DIR"/DepotDownloader* || true

  DEPOT_DOWNLOADER_BIN="$(find "$TOOLS_DIR" -type f -name 'DepotDownloader' | head -n1)"
  if [[ -z "$DEPOT_DOWNLOADER_BIN" ]]; then
    echo "DepotDownloader executable was not found after unzip." >&2
    exit 1
  fi

  cat >"$FILELIST" <<'FL'
RustDedicated_Data/Managed/Rust.Global.dll
FL

  "$DEPOT_DOWNLOADER_BIN" \
    -app "$RUST_APP_ID" \
    -depot "$RUST_DEPOT_ID" \
    -branch "$CHANNEL" \
    -dir "$DOWNLOAD_DIR" \
    -filelist "$FILELIST"

  RUST_GLOBAL_DLL="$(find "$DOWNLOAD_DIR" -type f -name 'Rust.Global.dll' | head -n1)"
  if [[ -z "$RUST_GLOBAL_DLL" ]]; then
    echo "Rust.Global.dll was not downloaded." >&2
    exit 1
  fi

  dotnet run --project "${ROOT_DIR}/tools/RustProtocolProbe" -- "$RUST_GLOBAL_DLL" >"$PROBE_JSON"
fi

PROTOCOL_NETWORK="$(jq -r '.protocol.network // empty' "$PROBE_JSON")"
PROTOCOL_PRINTABLE="$(jq -r '.protocol.printable // empty' "$PROBE_JSON")"
if [[ -z "$PROTOCOL_NETWORK" && -z "$PROTOCOL_PRINTABLE" ]]; then
  echo "Failed to read Rust protocol values." >&2
  exit 1
fi

CHECKED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg checked_at "$CHECKED_AT_UTC" \
  --arg channel "$CHANNEL" \
  --argjson rust_app_id "$RUST_APP_ID" \
  --argjson rust_depot_id "$RUST_DEPOT_ID" \
  --argjson rust_build_id "$BUILD_ID" \
  --arg rust_manifest_id "$MANIFEST_ID" \
  --slurpfile probe "$PROBE_JSON" \
  '{
    schema_version: 1,
    checked_at_utc: $checked_at,
    channel: $channel,
    rust: {
      app_id: $rust_app_id,
      depot_id: $rust_depot_id,
      build_id: $rust_build_id,
      manifest_id: (if $rust_manifest_id == "" then null else $rust_manifest_id end),
      protocol: ($probe[0].protocol // {})
    }
  }' >"$CANDIDATE_JSON"

if [[ -f "$PREV_RELEASE_JSON" ]]; then
  CURRENT_FINGERPRINT="$(jq -S 'del(.checked_at_utc)' "$PREV_RELEASE_JSON")"
  CANDIDATE_FINGERPRINT="$(jq -S 'del(.checked_at_utc)' "$CANDIDATE_JSON")"
  if [[ "$CURRENT_FINGERPRINT" == "$CANDIDATE_FINGERPRINT" ]]; then
    echo "Metadata unchanged vs latest release asset."
    exit 0
  fi
fi

mv "$CANDIDATE_JSON" "$OUT_JSON"

PROTOCOL_NETWORK_TAG="$(jq -r '.rust.protocol.network // "na"' "$OUT_JSON")"
BUILD_ID_TAG="$(jq -r '.rust.build_id // "na"' "$OUT_JSON")"
RELEASE_TS_COMPACT="$(date -u +%Y%m%d%H%M%S)"
RELEASE_TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RELEASE_TAG="rust-meta-${RELEASE_TS_COMPACT}-${CHANNEL}-b${BUILD_ID_TAG}-p${PROTOCOL_NETWORK_TAG}"
RELEASE_TITLE="${RELEASE_TS_ISO} Rust protocol ${CHANNEL} / build ${BUILD_ID_TAG} / protocol ${PROTOCOL_NETWORK_TAG}"

cat >"$RELEASE_NOTES" <<REL
Automatic Rust protocol metadata snapshot.

- Rust build_id: $(jq -r '.rust.build_id // "n/a"' "$OUT_JSON")
- Rust protocol network: $(jq -r '.rust.protocol.network // "n/a"' "$OUT_JSON")
REL

if [[ -n "$RUST_GLOBAL_DLL" && -f "$RUST_GLOBAL_DLL" ]]; then
  rm -f "$RUST_GLOBAL_DLL"
fi

gh release create "$RELEASE_TAG" \
  "$OUT_JSON" \
  --title "$RELEASE_TITLE" \
  --notes-file "$RELEASE_NOTES"
