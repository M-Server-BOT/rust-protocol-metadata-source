#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp/rust-metadata"
TOOLS_DIR="${ROOT_DIR}/.tools/depotdownloader"
OUT_JSON="${TMP_DIR}/rust-versions-public.json"
CANDIDATE_JSON="${TMP_DIR}/candidate.json"
PROBE_JSON="${TMP_DIR}/protocol.json"
OXIDE_JSON="${TMP_DIR}/oxide-release.json"
LATEST_RELEASE_JSON="${TMP_DIR}/latest-release.json"
PREV_RELEASE_JSON="${TMP_DIR}/prev-release.json"
RELEASE_NOTES="${TMP_DIR}/release-notes.txt"
FILELIST="${TMP_DIR}/filelist.txt"
DOWNLOAD_DIR="${TMP_DIR}/depot"
PRECHECK_JSON="${TMP_DIR}/precheck.json"
OXIDE_DATA_JSON="${TMP_DIR}/oxide-data.json"
PREV_OXIDE_JSON="${TMP_DIR}/prev-oxide.json"

CHANNEL="${RUST_CHANNEL:-public}"
RUST_APP_ID="${RUST_APP_ID:-258550}"
RUST_DEPOT_ID="${RUST_DEPOT_ID:-258552}"
STEAMDB_BRANCH="${STEAMDB_BRANCH:-${CHANNEL}}"
STEAMDB_DEPOTS_URL="${STEAMDB_DEPOTS_URL:-https://steamdb.info/app/${RUST_APP_ID}/depots/}"
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
require_bin sha256sum
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
PREV_RUST_GLOBAL_SHA256=""
PREV_MANIFEST_ID=""
PREV_RELEASE_TAG=""
echo 'null' >"$PREV_OXIDE_JSON"

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

    if [[ -n "$PREV_ASSET_API_URL" ]] && curl -fsSL "${GITHUB_ASSET_HEADERS[@]}" "$PREV_ASSET_API_URL" -o "$PREV_RELEASE_JSON"; then
      PREV_BUILD_ID="$(jq -r '.rust.build_id // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_MANIFEST_ID="$(jq -r '.rust.manifest_id // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_PROTOCOL_NETWORK="$(jq -r '.rust.protocol.network // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_PROTOCOL_PRINTABLE="$(jq -r '.rust.protocol.printable // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      PREV_RUST_GLOBAL_SHA256="$(jq -r '.rust.rust_global_dll.sha256 // empty' "$PREV_RELEASE_JSON" 2>/dev/null || true)"
      jq '.oxide // null' "$PREV_RELEASE_JSON" >"$PREV_OXIDE_JSON" || echo 'null' >"$PREV_OXIDE_JSON"
      echo "Loaded previous metadata from release asset (tag: ${PREV_RELEASE_TAG:-n/a})."
    else
      echo "Latest release found (${PREV_RELEASE_TAG:-n/a}), but rust-versions-public.json asset is unavailable."
    fi
  elif [[ "$RELEASE_HTTP_CODE" == "404" ]]; then
    echo "No previous GitHub release found yet (first release run)."
  else
    echo "Warning: failed to query latest release metadata (HTTP ${RELEASE_HTTP_CODE:-unknown}). Continuing without previous release state."
  fi
fi

STEAMDB_STATUS="error"
STEAMDB_ERROR=""
STEAMDB_BUILD_ID=""
STEAMDB_MANIFEST_ID=""
STEAMDB_TIME_UPDATED_UTC=""

echo "Web pre-check via api.steamcmd.net (branch: ${STEAMDB_BRANCH})..."
if curl -fsSL --compressed "$STEAMCMD_INFO_URL" -o "$PRECHECK_JSON"; then
  STEAMDB_BUILD_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$STEAMDB_BRANCH" \
    '.data[$app].depots[$depot].manifests[$branch].download // empty' "$PRECHECK_JSON")"
  STEAMDB_MANIFEST_ID="$(jq -r --arg app "$RUST_APP_ID" --arg depot "$RUST_DEPOT_ID" --arg branch "$STEAMDB_BRANCH" \
    '.data[$app].depots[$depot].manifests[$branch].gid // empty' "$PRECHECK_JSON")"
  if [[ -n "$STEAMDB_BUILD_ID" ]]; then
    STEAMDB_STATUS="ok"
    echo "Pre-check build_id=${STEAMDB_BUILD_ID} manifest_id=${STEAMDB_MANIFEST_ID:-n/a}"
  else
    STEAMDB_ERROR="api.steamcmd.net response did not contain build_id for depot ${RUST_DEPOT_ID} branch ${STEAMDB_BRANCH}."
    echo "$STEAMDB_ERROR"
  fi
else
  STEAMDB_ERROR="Failed to fetch pre-check metadata from api.steamcmd.net."
  echo "$STEAMDB_ERROR"
fi

echo "Fetching Oxide latest release metadata (best effort)..."
OXIDE_STATUS="ok"
OXIDE_ERROR=""
if ! curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest" \
  -o "$OXIDE_JSON"; then
  OXIDE_STATUS="error"
  OXIDE_ERROR="Failed to fetch Oxide latest release from GitHub API."
  echo "$OXIDE_ERROR"
fi

if [[ "$OXIDE_STATUS" == "ok" ]]; then
  jq '{
      latest_tag: .tag_name,
      published_at_utc: .published_at,
      html_url: .html_url,
      assets: (.assets // [] | map({
        name,
        size,
        content_type,
        browser_download_url,
        updated_at
      })),
      fetched_from_api: true
    }' "$OXIDE_JSON" >"$OXIDE_DATA_JSON"
else
  jq --arg err "$OXIDE_ERROR" '{ fetch_error: $err, fetched_from_api: false } + (. // {})' \
    "$PREV_OXIDE_JSON" >"$OXIDE_DATA_JSON"
fi

NEED_RUST_DLL_PROBE=1
RUST_PROTOCOL_PROBE_STATUS="ok"
RUST_GLOBAL_SHA256="${PREV_RUST_GLOBAL_SHA256}"
RUST_GLOBAL_DLL=""
DEPOT_VERSION="not-run"

if [[ "$STEAMDB_STATUS" == "ok" && -n "$STEAMDB_BUILD_ID" && "$STEAMDB_BUILD_ID" == "$PREV_BUILD_ID" ]]; then
  if [[ -n "$PREV_PROTOCOL_NETWORK" || -n "$PREV_PROTOCOL_PRINTABLE" ]]; then
    NEED_RUST_DLL_PROBE=0
    RUST_PROTOCOL_PROBE_STATUS="cached_same_build"
    jq -n \
      --argjson network "${PREV_PROTOCOL_NETWORK:-null}" \
      --arg printable "$PREV_PROTOCOL_PRINTABLE" \
      '{
        ok: true,
        protocol: {
          network: $network,
          printable: (if $printable == "" then null else $printable end)
        }
      }' >"$PROBE_JSON"
    echo "Rust build unchanged; reusing protocol from previous JSON."
  fi
fi

if [[ "$NEED_RUST_DLL_PROBE" -eq 1 ]]; then
  echo "Downloading latest DepotDownloader release metadata..."
  DEPOT_RELEASE_JSON="$(gh api repos/SteamRE/DepotDownloader/releases/latest)"
  DEPOT_VERSION="$(jq -r '.tag_name // .name // "unknown"' <<<"$DEPOT_RELEASE_JSON")"
  DEPOT_ASSET_URL="$(jq -r '
    .assets[]
    | select(.name | test("linux(-x64)?\\.zip$"; "i"))
    | .browser_download_url
    ' <<<"$DEPOT_RELEASE_JSON" | head -n1)"

  if [[ -z "${DEPOT_ASSET_URL}" || "${DEPOT_ASSET_URL}" == "null" ]]; then
    echo "Could not find a Linux DepotDownloader asset in latest release." >&2
    exit 1
  fi

  echo "Downloading DepotDownloader: ${DEPOT_ASSET_URL}"
  curl -fsSL "$DEPOT_ASSET_URL" -o "${TMP_DIR}/depotdownloader.zip"
  rm -rf "$TOOLS_DIR"/*
  unzip -q -o "${TMP_DIR}/depotdownloader.zip" -d "$TOOLS_DIR"
  chmod +x "$TOOLS_DIR"/DepotDownloader* || true

  DEPOT_DOWNLOADER_BIN="$(find "$TOOLS_DIR" -type f -name 'DepotDownloader' | head -n1)"
  if [[ -z "${DEPOT_DOWNLOADER_BIN}" ]]; then
    echo "DepotDownloader executable was not found after unzip." >&2
    exit 1
  fi

  cat >"$FILELIST" <<'FL'
RustDedicated_Data/Managed/Rust.Global.dll
FL

  echo "Downloading Rust.Global.dll from Steam depot ${RUST_DEPOT_ID} (${CHANNEL})..."
  "$DEPOT_DOWNLOADER_BIN" \
    -app "$RUST_APP_ID" \
    -depot "$RUST_DEPOT_ID" \
    -branch "$CHANNEL" \
    -dir "$DOWNLOAD_DIR" \
    -filelist "$FILELIST"

  RUST_GLOBAL_DLL="$(find "$DOWNLOAD_DIR" -type f -name 'Rust.Global.dll' | head -n1)"
  if [[ -z "${RUST_GLOBAL_DLL}" ]]; then
    echo "Rust.Global.dll was not downloaded." >&2
    exit 1
  fi

  RUST_GLOBAL_SHA256="$(sha256sum "$RUST_GLOBAL_DLL" | awk '{print $1}')"

  echo "Extracting Rust protocol from DLL..."
  dotnet run --project "${ROOT_DIR}/tools/RustProtocolProbe" -- "$RUST_GLOBAL_DLL" >"$PROBE_JSON"
fi

PROTOCOL_NETWORK="$(jq -r '.protocol.network // empty' "$PROBE_JSON")"
PROTOCOL_PRINTABLE="$(jq -r '.protocol.printable // empty' "$PROBE_JSON")"
if [[ -z "${PROTOCOL_NETWORK}" && -z "${PROTOCOL_PRINTABLE}" ]]; then
  echo "Failed to read Rust protocol values from Rust.Global.dll/probe cache." >&2
  exit 1
fi

CHECKED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_URL="https://github.com/${GITHUB_REPOSITORY:-local/local}/actions/runs/${GITHUB_RUN_ID:-0}"

jq -n \
  --arg checked_at "$CHECKED_AT_UTC" \
  --arg channel "$CHANNEL" \
  --arg steamdb_branch "$STEAMDB_BRANCH" \
  --arg steamdb_depots_url "$STEAMDB_DEPOTS_URL" \
  --argjson rust_app_id "$RUST_APP_ID" \
  --argjson rust_depot_id "$RUST_DEPOT_ID" \
  --argjson steamdb_build_id "${STEAMDB_BUILD_ID:-null}" \
  --arg steamdb_manifest_id "$STEAMDB_MANIFEST_ID" \
  --arg steamdb_status "$STEAMDB_STATUS" \
  --arg steamdb_error "$STEAMDB_ERROR" \
  --arg steamdb_time_updated "$STEAMDB_TIME_UPDATED_UTC" \
  --arg rust_global_path "RustDedicated_Data/Managed/Rust.Global.dll" \
  --arg rust_global_sha256 "$RUST_GLOBAL_SHA256" \
  --arg downloader_version "$DEPOT_VERSION" \
  --arg run_url "$RUN_URL" \
  --arg oxide_status "$OXIDE_STATUS" \
  --arg protocol_probe_status "$RUST_PROTOCOL_PROBE_STATUS" \
  --slurpfile probe "$PROBE_JSON" \
  --slurpfile oxide "$OXIDE_DATA_JSON" \
  '{
    schema_version: 1,
    checked_at_utc: $checked_at,
    channel: $channel,
    rust: {
      app_id: $rust_app_id,
      depot_id: $rust_depot_id,
      build_id: $steamdb_build_id,
      manifest_id: (if $steamdb_manifest_id == "" then null else $steamdb_manifest_id end),
      steamdb: {
        branch: $steamdb_branch,
        depots_url: $steamdb_depots_url,
        note: "SteamDB HTML may be blocked on GitHub-hosted runners; build_id/manifest_id pre-check currently comes from api.steamcmd.net.",
        probe_status: $steamdb_status,
        time_updated_utc_text: (if $steamdb_time_updated == "" then null else $steamdb_time_updated end),
        fetch_error: (if $steamdb_error == "" then null else $steamdb_error end)
      },
      rust_global_dll: {
        path: $rust_global_path,
        sha256: (if $rust_global_sha256 == "" then null else $rust_global_sha256 end)
      },
      protocol: ($probe[0].protocol // {})
    },
    oxide: ($oxide[0] // null),
    status: {
      steamdb_probe: $steamdb_status,
      rust_protocol_probe: $protocol_probe_status,
      oxide_release_probe: $oxide_status
    },
    source: {
      transport: "steam (DepotDownloader for DLL, api.steamcmd.net web for pre-check)",
      depot_downloader_release: $downloader_version,
      workflow_run_url: $run_url
    }
  }' >"$CANDIDATE_JSON"

if [[ -f "$PREV_RELEASE_JSON" ]]; then
  CURRENT_FINGERPRINT="$(jq -S 'del(.checked_at_utc, .source.workflow_run_url)' "$PREV_RELEASE_JSON")"
  CANDIDATE_FINGERPRINT="$(jq -S 'del(.checked_at_utc, .source.workflow_run_url)' "$CANDIDATE_JSON")"
  if [[ "$CURRENT_FINGERPRINT" == "$CANDIDATE_FINGERPRINT" ]]; then
    echo "Rust/Oxide metadata unchanged vs latest release asset."
    exit 0
  fi
fi

mv "$CANDIDATE_JSON" "$OUT_JSON"

echo "Metadata changed. Publishing new release asset (no git commit/push)."

PROTOCOL_NETWORK_TAG="$(jq -r '.rust.protocol.network // "na"' "$OUT_JSON")"
BUILD_ID_TAG="$(jq -r '.rust.build_id // "na"' "$OUT_JSON")"
OXIDE_TAG="$(jq -r '.oxide.latest_tag // "na"' "$OUT_JSON")"
OXIDE_TAG_SAFE="$(tr -cs '[:alnum:]._-' '-' <<<"$OXIDE_TAG" | sed 's/^-*//;s/-*$//')"
[[ -n "$OXIDE_TAG_SAFE" ]] || OXIDE_TAG_SAFE="na"
RELEASE_TAG="rust-meta-${CHANNEL}-b${BUILD_ID_TAG}-p${PROTOCOL_NETWORK_TAG}-o${OXIDE_TAG_SAFE}-$(date -u +%Y%m%d%H%M%S)"

cat >"$RELEASE_NOTES" <<REL
Automatic Rust/Oxide metadata snapshot.

Machine-readable fallback hints:
- metadata_asset_name=rust-versions-public.json
- build_id=$(jq -r '.rust.build_id // "n/a"' "$OUT_JSON")

- Channel: ${CHANNEL}
- Rust app/depot: ${RUST_APP_ID}/${RUST_DEPOT_ID}
- Rust build_id (web pre-check): $(jq -r '.rust.build_id // "n/a"' "$OUT_JSON")
- Rust manifest_id: $(jq -r '.rust.manifest_id // "n/a"' "$OUT_JSON")
- SteamDB probe status: $(jq -r '.status.steamdb_probe' "$OUT_JSON")
- Rust protocol probe status: $(jq -r '.status.rust_protocol_probe' "$OUT_JSON")
- Rust protocol network: $(jq -r '.rust.protocol.network // "n/a"' "$OUT_JSON")
- Rust protocol printable: $(jq -r '.rust.protocol.printable // "n/a"' "$OUT_JSON")
- Rust.Global.dll sha256: $(jq -r '.rust.rust_global_dll.sha256 // "n/a"' "$OUT_JSON")
- Oxide release probe status: $(jq -r '.status.oxide_release_probe' "$OUT_JSON")
- Oxide latest tag: $(jq -r '.oxide.latest_tag // "n/a"' "$OUT_JSON")
- Previous release tag (if any): ${PREV_RELEASE_TAG:-n/a}
REL

if [[ -n "$RUST_GLOBAL_DLL" && -f "$RUST_GLOBAL_DLL" ]]; then
  echo "Removing temporary Rust.Global.dll before release packaging..."
  rm -f "$RUST_GLOBAL_DLL"
fi

echo "Creating release ${RELEASE_TAG}..."
gh release create "$RELEASE_TAG" \
  "$OUT_JSON" \
  --title "Rust metadata ${CHANNEL} / build ${BUILD_ID_TAG} / protocol ${PROTOCOL_NETWORK_TAG}" \
  --notes-file "$RELEASE_NOTES"
