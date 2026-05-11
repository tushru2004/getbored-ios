# GetBored iOS — Project Instructions

## What this repo owns

iOS app, FilterDataProvider, SafariAppProxy, and iOS system extensions for content filtering and app lockdown on iPad/iPhone.

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
