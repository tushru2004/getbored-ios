# Safari Content Blocker — Implementation Plan (spike #170 → production)

Status: revised after GPT-5.6 Sol review. Branch `feat/ios-whitelist-integration`.
No issue edits.

## 1. Goal

Replace the hardcoded Docker spike with a real implementation.

- The Safari Content Blocker builds its rules from the **live filter list** (synced
  over CloudKit and stored in the App Group — the shared storage the app and its
  extension both use) instead of a fixed JSON file bundled into the app.
- Keep the contextual whitelist behavior: an approved page may load its own
  child/CDN resources, but navigating directly to those child hosts stays blocked.
- The Network Extension (NE) stays as the device-wide safety net. The whitelist
  feature was removed from the current release and is disabled in the admin UI
  today; this work restores it for Safari. The NE's existing
  `whiteList`→`blockSpecific` coercion is left untouched (do not remove; see D6).
- Fix the known lease/refresh defects from the spike, with honest behavior when
  things go wrong (see D4).

## 2. Current spike state (what changes)

- `ContentBlockerRequestHandler` returns a fixed bundled `ContentBlockerRules.json`
  (block all, allow docker.com documents, allow subresources under docker.com).
- `SafariContentBlockerState.refresh()` clears the lease at the start, has no
  refresh ID (so an outdated refresh can overwrite a newer one), no
  `synchronize()`, and runs twice at launch.
- Rules reload only on app launch / foreground / every 60s — not when the synced
  list actually changes.
- Four leftover Xcode test targets point at source files that no longer exist.

## 3. Design decisions

### D1 — One snapshot key, written by the app, read by the extension

The app writes a **single** snapshot key `safari_content_blocker_snapshot`
(JSON: schema version, mode, hosts, exceptions) in one `set` + `synchronize()`
inside `IOSRuleStore.applyFilterListSnapshot`.

The Content Blocker extension reads only that one key — never the separate
`filter_mode`/`site_rules` keys. This way it can never see a half-finished policy
(the new mode paired with the old list). The extension stays self-contained: it
only needs the fixed suite name to reach the shared storage, no GetBoredCore
dependency.

If the snapshot is missing or unreadable, the extension returns a tiny **bundled
fallback rule list** that blocks everything (it never returns an empty list). This
also covers a fresh install before the first sync. The trade-off: a `blockSpecific`
user (who normally blocks only a few sites) would briefly see *everything* blocked
in Safari until the list is readable again. We accept this because blocking too much
is safer than blocking too little — if we instead allowed everything, the filter
would silently stop working.

### D2 — What each mode means, now consistent with the NE

- **`whiteList` mode**: block everything, allow documents/popups whose own host is
  on the list, and allow subresources under an approved top URL. Example:
  `docker.com` is approved, so the docker.com page and its assets load, but other
  sites are blocked.
- **`blockSpecific` mode**: block only the listed hosts; everything else is allowed.
- **Path exceptions** (`filter_exceptions`, e.g. `instagram.com/school-account`):
  included in the snapshot and turned into `ignore-previous-rules` rules, so Safari
  keeps the NE's exception behavior (the specific path is allowed even though the
  host is blocked).
- **System domains**: the extension bundles the same `SystemAllowList` the NE uses
  and emits allow rules for those suffixes, so Apple's own infrastructure stays
  reachable.
- **Safari in `blockedAppBundleIDs`**: if the admin has blocked Mobile Safari itself,
  the Safari skip must not apply. `FlowInspector.shouldSkipForSafariContentBlocker`
  gains a guard: skip only when Safari is *not* in the blocked-apps list, so the NE
  keeps dropping Safari exactly as it does today.
- **Empty list**: `whiteList` + empty → block everything. `blockSpecific` + empty →
  a single no-op rule (matches nothing). Never return an empty list.

### D3 — Iframes (child-document) — DECISION POINT

Loose policy: include `child-document` in the subresource allow rule so iframes on
an approved page load. **Recommendation: include it**, behind a single constant.
WebKit's accepted resource-type names aren't fully public, so the implementation
validates the generated JSON through `WKContentRuleListStore.compileContentRuleList`
(a macOS script, same check used for the spike) before shipping. If `child-document`
is rejected, fall back to omitting it (tight policy) and log the decision.

### D4 — Refresh redesigned as a serialized state machine

Background: the Content Blocker and the NE share a short-lived **lease** — a signal
that says "the Content Blocker is handling Safari now, so the NE should leave Safari
alone." When the lease expires, the NE takes Safari back over (the fail-closed safety
net).

- All refresh work (state, writes) lives behind a private serial queue (or
  `@MainActor`). Each refresh gets an ID, and every async callback checks that ID
  before writing — so an outdated, slow refresh can't overwrite a newer one.
- **No blank-at-start.** Disabled/error paths still publish `false` explicitly.
  Documented behavior: if the user disables the blocker in Settings and the app is
  killed before the next refresh finishes, the NE may continue ignoring Safari for up
  to 120 seconds until the old lease expires. That is a bounded fail-open window,
  not an instant fail-closed one.
- Add `synchronize()` after lease writes.
- Coalescing: lifecycle/timer refreshes are skipped if one already started <1s ago
  (avoid redundant work). **Policy-triggered reloads bypass this** via a
  `refresh(force:)` path that queues a pending reload if one is in flight.
- **No BGAppRefreshTask in first ship** (Sol: opportunistic background tasks can't
  reliably maintain a 2-minute lease; omit until fully designed). Recorded as a
  future item.

### D5 — Reload when the list changes

After every `applyFilterListSnapshot` call (`FilterStatusModule.swift:376,444`,
`AccountModule.swift:192`), call `SafariContentBlockerState.refresh(force: true)` so
Safari recompiles rules from the new snapshot immediately.

### D6 — NE stays block-mode-only (constraint preserved)

The `whiteList`→`blockSpecific` coercion in `IOSRuleStore.decodedFilterMode()` is
untouched. (The NE only understands block-lists, so when the mode is `whiteList`,
the code currently reinterprets the list as a blocklist.) Consequence, documented
and not fixed here: in whiteList mode the Content Blocker is the **only** whitelist
enforcement point, and it covers Safari only. Non-Safari apps in whiteList mode keep
v1 behavior (the list is treated as a blocklist). Extending NE-side whitelist support
is a separate future item.

### D7 — Bundled JSON becomes the fallback, not the source

`ContentBlockerRules.json` is replaced by a minimal `FallbackRules.json` (block-all
only), returned when the snapshot is unreadable/malformed. The dynamic path is
validated before the old Docker JSON is deleted.

### D8 — Remove dangling test targets completely

Delete `SafariTestHarness`, `SafariDeviceUITests`, `SafariSimulatorUITests`,
`GetBoredUITests` from `GetBoredIOS.xcodeproj`, including all Xcode project entries
connected to those targets: targets, build configurations and configuration lists,
target dependencies, container item proxies, file/build references, groups, products,
and project target/product entries. Validate the shared scheme still parses and
builds afterward.

### D9 — No unit tests

Per project preference, validation is source inspection + signed device build +
manual tests. No new test files.

## 4. Work items (ordered — Sol's ordering)

1. **New** `Sources/iOS/iOSSafariContentBlocker/SafariRuleGenerator.swift`
   (the Safari Content Blocker extension target): host normalization (lowercase,
   strip scheme/port/path), regex escaping, subdomain-safe pattern
   `^https?://([a-z0-9-]+\.)*host([:/].*)?$`, combine host patterns and split them
   into groups of 100 per rule, explicit caps (max 10,000 hosts, dedupe, reject
   invalid hosts, deterministic output), JSON built with
   `JSONSerialization`/`Encodable` (no string interpolation), mode + exceptions +
   system-domain rules per D2/D3.
2. **Edit** `ContentBlockerRequestHandler.swift`: read the atomic snapshot key,
   generate rules, keep the non-empty-array guard, return `FallbackRules.json` on
   unreadable/malformed snapshot.
3. **Validate** generated JSON with the macOS `WKContentRuleListStore` compile-check
   script (both modes, empty lists, max-size sample) before touching the device.
4. **Edit** `SafariContentBlockerState.swift`: serialized state machine, per-refresh
   ID so outdated callbacks can't save, no blank-at-start, `synchronize()`, coalesced
   `refresh()` + `refresh(force:)` (D4).
5. **Edit** `FlowInspector.swift`: blocked-apps guard on the Safari skip (D2).
6. **Edit** `IOSRuleStore.swift`: write the atomic snapshot key inside
   `applyFilterListSnapshot` (D1).
7. **Edit** `FilterStatusModule.swift` + `AccountModule.swift`: call
   `refresh(force: true)` after each snapshot apply (D5).
8. **Edit** `AppDelegate.swift`: keep launch/foreground/60s timer on the coalesced
   path (D4).
9. **Edit** `project.pbxproj`: add `SafariRuleGenerator.swift` + the `SystemAllowList`
   resource + `FallbackRules.json` to the extension target; remove the four dangling
   test targets (see D8 for the full list of entries).
10. **Delete** the Docker `ContentBlockerRules.json` only after step 3 passes.
11. **Docs**: update `docs/safari-content-blocker-spike.md` status to implemented;
    document D2 semantics, D4 lease model and its bounded fail-open window, D6
    limitation, D7 fallback. Update `scratchpad/spike-170-contract.md` to note rules
    are now dynamic.

## 5. Validation (no unit tests)

- `git diff --check`; the Xcode project file still parses; signed device build
  succeeds.
- `make install` on iPhone XR; bundle inspection: the extension bundle contains the
  fallback JSON, the App Group entitlement, and the unchanged extension point.
- Manual test checklist (user runs):
  1. whiteList mode with `docker.com`: docker.com renders with assets; direct
     navigation to a docker CDN host blocked; other sites show the content-blocker
     page.
  2. If D3 accepted: an iframe on an approved page loads; direct navigation to the
     iframe host stays blocked.
  3. Path exception (whiteList mode): `host/path` allowed while `host` blocked.
  4. blockSpecific mode with a listed host: blocked in Safari; unlisted loads.
  5. Empty whiteList: everything blocked in Safari.
  6. Toggle the extension off, foreground the app: after lease expiry the NE resumes
     Safari (listed host shows the system "content filter" page).
  7. Force-quit + 10 min: whiteList mode → NE blocks listed hosts; blockSpecific mode
     → unlisted hosts keep loading (expected, per D6).
  8. Chrome and TikTok remain NE-filtered throughout.

## 6. Risks

- WebKit rule-size limits → the caps + chunking (item 1) and compile validation
  (item 3) bound this.
- `child-document` may be rejected by WebKit → validated fallback to tight policy
  (D3).
- Bounded fail-open window (≤120 s) after disabling the blocker while the app is
  killed mid-refresh (D4) — documented trade-off.
- First-install/unreadable-snapshot fallback is block-all (D7) — blocks everything
  rather than allowing everything.
- whiteList mode for non-Safari apps remains v1 blockSpecific behavior (D6).
