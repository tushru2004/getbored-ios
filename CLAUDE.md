# GetBored iOS — Project Instructions

## What this repo owns

iPhone app, FilterDataProvider, SafariAppProxy, and iOS system extensions for content filtering and app lockdown. The shipping app targets iPhone only, not iPadOS.

## Agent routing

All iOS filter and extension work routes to the iOS filter engineer.

| Path glob | Agent | Model |
|---|---|---|
| `Sources/iOS/**`, `Sources/Shared/**` | ios-filter-engineer | sonnet (Opus-escalating for spike branches) |
| `tests/iOS/**` | ios-filter-engineer | sonnet |
| Architecture spikes (parent-child, new extension types) | Opus plan first → ios-filter-engineer | opus → sonnet |

## Commit rules
See `~/.claude/skills/commit-rules/` — invoked at commit time, not loaded every message.

## Cross-cutting

For cross-repo architecture decisions (iOS + macOS + browser), see `tushru2004/getbored` CLAUDE.md.

## Pairing wedge quick recovery

If iPhone shows "unpaired" in Xcode after a build/install cycle, see `docs/recovery-pairing-wedge.md` for the full runbook. Top-3 commands:

1. `xcrun devicectl list devices --verbose | grep -A 30 'iPhone XR'` (verify `tunnelState=unavailable`)
2. `system_profiler SPUSBDataType | grep -B 1 -A 6 -iE 'iPhone|Apple Mobile'` (verify USB still sees the phone)
3. Disable the GetBored filter on the phone, unplug, replug, tap Trust, then re-run `make install`.
