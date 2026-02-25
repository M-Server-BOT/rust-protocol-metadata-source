# Rust Protocol Metadata Source

Scheduled GitHub Actions workflow that publishes a unified JSON source for:

- Rust dedicated server build/manifest metadata (web pre-check via `api.steamcmd.net`)
- Rust network protocol (`Rust.Global.dll` parsed via DepotDownloader + Mono.Cecil)
- Oxide latest release metadata (best effort)

The workflow performs a lightweight web pre-check first and skips `.NET` setup / DLL download when the Rust `build_id` is unchanged.
