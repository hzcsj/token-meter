# TokenMeter

A macOS menu bar app that tracks local token usage and costs for AI coding tools.

## Features

- **Claude Code usage tracking** — Scans `~/.claude/projects/**/*.jsonl` for token consumption
- **Codex usage tracking** — Scans `~/.codex/sessions/**/*.jsonl` for token consumption, supplemented by `~/.codex/logs_2.sqlite` for side/temporary chat sessions not present in JSONL (tokens exact, cost estimated via daily effective-rate)
- **Codex quota monitoring** — Displays 5H/7D rolling window quota remaining
- **Multi-model pricing** — Supports Claude, GPT, Qwen, GLM, DeepSeek with per-model cost calculation
- **Dual currency** — USD models auto-converted to CNY; CNY-native models priced directly
- **Incremental scanning** — mtime+size based cache for fast refreshes
- **Daily breakdown** — Token count, message count, and cost per day (recent 7 days + weekly/monthly/all-time totals)

## Requirements

- macOS 13.0+
- Swift 5.9+

## Build & Install

```bash
# Build
swift build -c release

# Install (builds, creates .app, sets up LaunchAgent)
bash scripts/install.sh
```

## How It Works

TokenMeter runs as a menu bar app (no Dock icon). Every 5 minutes it:

1. Scans Claude Code JSONL logs for assistant messages with token usage
2. Scans Codex JSONL logs for token_count events and rate_limit quota data; supplements with logs_2.sqlite for logs-only side/temporary chats (deduplicated by JSONL thread IDs)
3. Calculates cost using `pricing.json` (per-model pricing, supports USD and CNY)
4. Renders today's token count + cost in the menu bar
5. Shows a dropdown with daily breakdown, weekly/monthly totals, and Codex quota status

## Pricing

Model prices are defined in `Resources/pricing.json`. To add a new model, add an entry to the appropriate section:

- `models_usd_per_mtok` — For Claude Code models (USD per million tokens)
- `codex_models_usd_per_mtok` — For Codex/GPT models (USD per million tokens)
- `long_context_threshold` / `long_*` — Optional Codex long-context rates (GPT-5.6/5.5/5.4 use the official 272K threshold)

Models with `"currency": "CNY"` are priced directly in CNY.
Virtual costs use official standard list prices; temporary promotions, Batch, and Flex discounts are intentionally ignored.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.user.tokenmeter.plist
rm ~/Library/LaunchAgents/com.user.tokenmeter.plist
rm -rf /Applications/TokenMeter.app
rm -rf ~/Library/Caches/token-meter/
```

## License

MIT
