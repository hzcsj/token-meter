<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="TokenMeter app icon">
</p>

<h1 align="center">TokenMeter</h1>

<p align="center">
  A native macOS menu bar app for tracking local AI coding token usage, estimated cost, and Codex quotas.
</p>

TokenMeter gives Claude Code, Codex, and OpenCode users one lightweight view of their local usage. It runs without a Dock icon, refreshes automatically, and keeps usage processing on the Mac.

## Features

- Tracks Claude Code usage from local JSONL session logs.
- Tracks Codex usage and model-aware estimated cost from local sessions, including side and temporary chats found only in the local SQLite log database.
- Reads OpenCode assistant usage from its local SQLite database, including live WAL data.
- Shows Codex rolling quota windows and reset timing.
- Aggregates daily, weekly, monthly, and all-time token counts, calls, and cost.
- Breaks down mixed-source totals in field-level hover details.
- Uses incremental caches for quick refreshes after the first scan.
- Supports USD and CNY price tables through `Resources/pricing.json`.

## Requirements and compatibility

| Requirement | Support |
| --- | --- |
| macOS | macOS 13 Ventura or later |
| GitHub Release CPU support | Universal binary: Apple Silicon (`arm64`) and Intel (`x86_64`) |
| Source build tools | Xcode Command Line Tools with Swift 5.9 or later |

TokenMeter is a menu bar app (`LSUIElement`) and does not show a Dock icon.

## Install

### 1. Download from GitHub Releases

1. Open the [TokenMeter Releases page](https://github.com/hzcsj/token-meter/releases).
2. Download `TokenMeter-v0.2.1-macos-universal.zip` and `SHA256SUMS`.
3. Optionally verify the download from the directory containing both files:

   ```bash
   shasum -a 256 -c SHA256SUMS
   ```

4. Unzip the archive and move `TokenMeter.app` to `/Applications`.
5. Open TokenMeter. Use **设置与退出…** to control **随系统启动**, or quit with `⌘Q`.

See [Signing, notarization, and Gatekeeper](#signing-notarization-and-gatekeeper) before the first launch.

### 2. Build and install from source

```bash
git clone https://github.com/hzcsj/token-meter.git
cd token-meter
bash scripts/install.sh
```

The source installer builds for the current Mac architecture, installs `/Applications/TokenMeter.app`, and creates the `io.github.hzcsj.tokenmeter` LaunchAgent. First installs enable login start by default. Later installer runs preserve an explicit disabled choice made in the app. Upgrading also removes the legacy `com.user.tokenmeter` LaunchAgent to prevent duplicate processes.

To create a release bundle without installing anything or changing `launchctl` state:

```bash
bash scripts/package.sh --arch universal --output-dir dist
```

This produces `dist/TokenMeter.app` and `dist/TokenMeter-v0.1.0-macos-universal.zip` without writing to `/Applications`.

## Signing, notarization, and Gatekeeper

The v0.1.0 public artifacts are **not signed with an Apple Developer ID and are not notarized by Apple**. Gatekeeper may therefore block the first launch of a downloaded build.

Do not disable Gatekeeper globally. In Finder, Control-click `TokenMeter.app`, choose **Open**, then confirm **Open**. If macOS still blocks the app, review it under System Settings → Privacy & Security.

## Privacy

TokenMeter scans supported logs and databases locally and read-only:

- Claude Code and Codex JSONL logs are opened for local parsing only.
- Codex and OpenCode SQLite databases are opened in read-only mode; TokenMeter does not checkpoint or mutate their WAL files.
- Token usage, prompts, logs, and derived cost data are not uploaded by TokenMeter.
- The incremental usage cache remains local under `~/Library/Caches/token-meter/`.

The app contains no telemetry or analytics service. Its bundled pricing table is local.

## How it works

Every five minutes TokenMeter:

1. Scans Claude Code assistant messages in `~/.claude/projects/**/*.jsonl`.
2. Scans Codex sessions in `~/.codex/sessions/**/*.jsonl` and supplements them with deduplicated side or temporary chats from `~/.codex/logs_2.sqlite`.
3. Reads OpenCode assistant messages from `~/.local/share/opencode/opencode.db` using a read-only SQLite connection.
4. Calculates virtual cost using the bundled pricing table.
5. Updates the menu bar summary, detailed history, and Codex quota windows.

Set `OPENCODE_DB_PATH` to override the default OpenCode database location. Missing, corrupt, or incompatible rows are skipped without preventing the other sources from loading.

## Pricing

Model prices are defined in `Resources/pricing.json`:

- `models_usd_per_mtok` contains Claude and other USD-denominated model rates.
- `codex_models_usd_per_mtok` contains Codex/GPT rates.
- `long_context_threshold` and `long_*` contain optional long-context rates.

Virtual costs use standard list prices and intentionally exclude temporary promotions, Batch, and Flex discounts. Models whose names contain `dogfooding` are counted but remain free.

## Development

```bash
swift test
swift build -c release
bash -n scripts/*.sh
```

Release metadata is centralized in `scripts/app-config.sh`. A Git tag must match the configured app version before the release workflow packages and retains its release assets. Publishing the public GitHub Release remains a separate, explicit step.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/io.github.hzcsj.tokenmeter.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/io.github.hzcsj.tokenmeter.plist
rm -rf /Applications/TokenMeter.app
rm -rf ~/Library/Caches/token-meter/

# Legacy pre-v0.1.0 LaunchAgent cleanup, if still present
launchctl unload ~/Library/LaunchAgents/com.user.tokenmeter.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.user.tokenmeter.plist
```

## License

[MIT](LICENSE)
