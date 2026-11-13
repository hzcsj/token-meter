# Codex compressed rollout recovery (0.2.12)

## Cause and introduction

The scanner has filtered on `pathExtension == "jsonl"` since the initial
commit `c9bb8a5` (July 6, 2026). Codex subsequently began storing older rollouts
as `.jsonl.zst`. These still contain the original JSONL records, but the old
scanner skipped them and removed their plain-path incremental-cache entries.
Pricing-key changes also rebuild from visible sources and could expose the
same omission. This is a missing format compatibility feature, not deletion of
the original usage by a pricing update. The affected local archive migration
was observed in the October 15 period; that observation does not establish a
universal Codex rollout date.

## Changes

- Scan both formats in `sessions` and `archived_sessions` using the same parser,
  event timestamps, model/service-tier context and historical prices.
- Bundle the official BSD-licensed Zstandard decoder. Stream 128 KiB chunks;
  never load an entire expanded rollout or write extracted conversations to disk.
  Decoder windows are capped at 128 MiB and individual lines at 64 MiB. Exceeding
  either limit is a read failure, not silently counted as an empty file.
- During archive migration, plain/compressed copies with the same logical
  rollout filename count once. Plain files take precedence; a readable archive
  is a fallback. Archived thread IDs also suppress duplicate logs-only estimates.
- Reject corrupt/truncated compressed streams. Do not cache failed reads;
  reuse a valid file cache when available, otherwise retain the previous Codex
  summary until a complete scan succeeds. Retrying does not establish login or
  display subscription quotas for unsigned-in users.
- Cache only stable file signatures. The v7 cache namespace rebuilds independently
  of old caches; no original files or previous caches are deleted.
- Skip cache writes when neither entries nor cleanup results change. Parsing
  remains off the UI actor; timestamp formatters are reused within each file.
  Autorelease pools cover chunk reads, file parsing and aggregation so background
  actors do not retain Foundation temporaries until the full scan returns.
- Claude and Codex single-source weekly totals now use calendar days, not the
  last seven days with activity.

## Scope

This restores locally retained compressed history. It does not reconstruct
actually deleted source files or create an append-only ledger. Account-wide
profile totals may include other devices or use a different counting method.
Quota fetching, activity-based polling, authentication and preferences are
unchanged. On a pricing-key change, the normal loading state remains visible
until the first complete scan; later starts restore the small usage snapshot.
The menu-bar placeholder is `Loading`.

## Validation

Regression coverage includes UTF-8 split across chunks, CRLF, final lines without
a newline, multiple zstd frames, large lines, empty/corrupt/truncated archives,
plain/archive overlap, warm restart, stable cache modification time, failed-read
recovery, model/tier pricing and no-login display behavior. A separate opt-in
local verification reads actual source files into an isolated temporary cache.

A release-mode local verification of 583 rollouts (including 483 compressed
archives) completed its cold scan in about 113 seconds and a subsequent warm
scan in about 1.2 seconds. These are measurements on one machine, not guarantees
for every history size or device. Packaging and Swift compiler memory are not
included in claims about scanner memory usage.

The installed menu-bar application was also checked through a complete cold
rebuild. This exposed worker-actor autorelease accumulation not reproduced by
the synchronous XCTest scan; the chunk/file/scan pools above address it.
Post-fix spot checks stayed below 650 MiB RSS during scanning and dropped after
completion, rather than growing by gigabytes. This is an observed sample, not
a fixed memory ceiling for arbitrary rollout lines or history sizes.

The broader regression run passed 129 tests and skipped two opt-in tests after
excluding the pre-existing interactive submenu test
`testRepeatedControlClicksDoNotEndTrackedSubmenu`. A full run still reproduced
that test's two assertions previously documented in the November 6 release;
the menu interaction implementation is unchanged here. The local archive
verification was also run separately with explicit opt-in and passed.
