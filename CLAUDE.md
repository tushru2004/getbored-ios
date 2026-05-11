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

## Commit message rules

Use **Conventional Commits** format:

```
type(scope): short description

Refs: tushru2004/GetBored#N
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `perf`

**Scopes:** `ios`, `filter`, `safari`, `lockdown`

**Footer:** Always include `Refs:` or `Fixes:` referencing an issue in the monorepo project.

**Rules:**
- Never add `Co-Authored-By` lines
- Only commit when explicitly asked by the user

## Cross-cutting

For cross-repo architecture decisions (iOS + macOS + browser), see `tushru2004/getbored` CLAUDE.md.
