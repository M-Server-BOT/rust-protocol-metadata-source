#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.tmp/rust-metadata"
TOOLS_DIR="${ROOT_DIR}/.tools/depotdownloader"
OUT_JSON="${TMP_DIR}/rust-versions-public.json"
PROBE_JSON="${TMP_DIR}/protocol.json"
RELEASE_NOTES="${TMP_DIR}/release-notes.txt"
FILELIST="${TMP_DIR}/filelist.txt"
DOWNLOAD_DIR="${TMP_DIR}/depot"
PRECHECK_JSON="${TMP_DIR}/precheck.json"

CHANNEL="${RUST_CHANNEL:-public}"
RUST_APP_ID="${RUST_APP_ID:-258550}"
RUST_DEPOT_ID="${RUST_DEPOT_ID:-258552}"
STEAMCMD_INFO_URL="${STEAMCMD_INFO_URL:-https://api.steamcmd.net/v1/info/${RUST_APP_ID}}"

for bin in curl jq unzip dotnet gh; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Missing required command: $bin" >&2
    exit 1
  }
done

mkdir -p "$TMP_DIR" "$TOOLS_DIR"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

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

DEPOT_RELEASE_JSON="$(gh api repos/SteamRE/DepotDownloader/releases/latest)"
DEPOT_ASSET_URL="$(jq -r '.assets[] | select(.name | test("linux(-x64)?\\.zip$"; "i")) | .browser_download_url' <<<"$DEPOT_RELEASE_JSON" | head -n1)"

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

PROTOCOL_NETWORK="$(jq -r '.protocol.network // empty' "$PROBE_JSON")"
PROTOCOL_PRINTABLE="$(jq -r '.protocol.printable // empty' "$PROBE_JSON")"
if [[ -z "$PROTOCOL_NETWORK" && -z "$PROTOCOL_PRINTABLE" ]]; then
  echo "Failed to read Rust protocol values." >&2
  exit 1
fi

jq -n \
  --arg channel "$CHANNEL" \
  --argjson rust_app_id "$RUST_APP_ID" \
  --argjson rust_depot_id "$RUST_DEPOT_ID" \
  --argjson rust_build_id "$BUILD_ID" \
  --arg rust_manifest_id "$MANIFEST_ID" \
  --slurpfile probe "$PROBE_JSON" \
  '{
    schema_version: 1,
    channel: $channel,
    rust: {
      app_id: $rust_app_id,
      depot_id: $rust_depot_id,
      build_id: $rust_build_id,
      manifest_id: (if $rust_manifest_id == "" then null else $rust_manifest_id end),
      protocol: ($probe[0].protocol // {})
    }
  }' >"$OUT_JSON"

RELEASE_TAG="rust-meta-${CHANNEL}-b${BUILD_ID}-p${PROTOCOL_NETWORK}"
RELEASE_TITLE="Rust protocol ${CHANNEL} / build ${BUILD_ID} / protocol ${PROTOCOL_NETWORK}"

cat >"$RELEASE_NOTES" <<REL
Automatic Rust protocol metadata snapshot.

- Rust build_id: ${BUILD_ID}
- Rust protocol network: ${PROTOCOL_NETWORK}
REL

gh release create "$RELEASE_TAG" \
  "$OUT_JSON" \
  --title "$RELEASE_TITLE" \
  --notes-file "$RELEASE_NOTES"
