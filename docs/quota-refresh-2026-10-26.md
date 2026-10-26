# Adaptive quota refresh in 0.2.10

The official account client and main-bucket selection are unchanged. This release reduces how often TokenMeter launches that client, rather than changing authentication, network routing or quota interpretation.

| Trigger / state | Request policy |
| --- | --- |
| Startup | One initial attempt |
| Recent local Codex activity | Every 5 minutes |
| No recent local Codex activity | Every 30 minutes |
| Menu open | On demand, at least 60 seconds after the last attempt |
| Wake | Apply the active/idle interval; elapsed sleep can make a read due |
| Known signed-out / non-subscription account | 30-minute background interval, even with local activity |

All attempts share the rolling 60-second gate, including failures. An in-flight request is never duplicated. The periodic one-minute timer only checks local activity and the due time and refreshes the countdown; it does not unconditionally launch the account client. Steady-state background launches fall from 60 per hour to 12 while active or 2 while idle, excluding startup and menu interaction. This is a request-frequency reduction, not a measured guarantee of proportional byte savings.

## Local-only activity

Activity means a session JSONL file was modified or a thread-scoped inference/tool event was recorded in the last five minutes. Session metadata is inspected without parsing transcript contents. The local Codex SQLite log database is opened read-only with bounded query time; only timestamp, target and thread-presence fields are examined. Threadless account-client housekeeping, other log targets, app process existence and unrelated WAL writes do not establish activity. Missing/corrupt/unsupported data falls back to the idle schedule. This is a recent-activity heuristic, not an assertion that a particular turn is still running.

No network operation is used to detect activity. Usage collection still runs locally on its existing five-minute cadence, independently of the quota request cadence. Reset countdowns are computed locally. Missing subscriptions still show usage only, without initiating login.

## Validation

- Deterministic clock tests cover active/idle transitions, minute-boundary debounce, wake/sleep, clock rollback, failures and in-flight coalescing.
- Synthetic local session and WAL fixtures cover activity expiry, resumed writes, temporary-thread activity, housekeeping rejection and missing/corrupt schemas.
- Pricing tests cover Argon's promotional boundary and preserve existing history; see the [pricing audit](pricing-2026-10-26.md).
- 114 tests ran with no failures and one opt-in live-account test skipped after excluding one existing interactive menu test. That excluded test, `testRepeatedControlClicksDoNotEndTrackedSubmenu`, fails the same two assertions on the untouched 0.2.9 baseline in this desktop session. Its code and settings behavior are unchanged by this release.
