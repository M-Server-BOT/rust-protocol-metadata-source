# Rust Protocol Metadata Source

Minimal GitHub Actions pipeline that publishes `rust-versions-public.json` for each new Rust server build.

What it does:
- Web pre-check (`api.steamcmd.net`) to read current `build_id`/`manifest_id`.
- Skips heavy work if `build_id` matches the latest release asset.
- Downloads `Rust.Global.dll`, extracts protocol via `tools/RustProtocolProbe`, and publishes a new GitHub release asset.

Scope is intentionally narrow: Rust build + protocol only.
