# Safari Content Blocker spike (#170) — Content Blocker half

Status: **spike, hardcoded Docker allow-list, not production.**

This document covers the **Content Blocker** half of spike #170. The other half —
the Safari-only Network Extension skip in `FlowInspector` / `IOSDecisionCore` — is
owned separately and is not described here.

Contract of record: `scratchpad/spike-170-contract.md`.

---

## What this is

Mobile Safari gets its own declarative allow-list, enforced by Safari's own
Content Blocker extension instead of the Network Extension. Two moving parts:

1. **`iOSSafariContentBlocker` appex** — vends a static WKContentRuleList JSON.
   Block everything, then carve Docker back out. Embedded in the GetBored iOS app.
2. **`SafariContentBlockerState` (App target)** — mirrors the extension's enabled
   state into the App Group as a short-lived lease (`safariContentBlockerEnabled`
   + `safariContentBlockerEnabledAt`), which the Network Extension reads to
   decide whether to step aside for Mobile Safari flows.

Rules are served from the **appex bundle**, not from the App Group. The handler
never reads App Group state and never mutates rules per-request.

---

## Frozen IDs

| Thing | Value |
| --- | --- |
| Extension point | `com.apple.Safari.content-blocker` |
| Extension bundle id | `com.getbored.filter.safaricontentblocker` |
| App Group | `group.com.getbored.ios` |
| Team | `3A3AVFF22Q` |
| App Group UserDefaults key (flag) | `safariContentBlockerEnabled` (Bool) |
| App Group UserDefaults key (lease) | `safariContentBlockerEnabledAt` (Double, seconds since 1970) |
| Principal class | `iOSSafariContentBlocker.ContentBlockerRequestHandler` |

`GetBoredIdentifiers.Bundle` in `getbored-core` has **no** entry for the content
blocker bundle id yet, so `SafariContentBlockerState.extensionBundleID` holds the
literal. When this leaves spike status, add
`GetBoredIdentifiers.Bundle.iosSafariContentBlocker` upstream and switch the App
to reference it — the identifiers file is the project's single source of truth for
bundle ids.

---

## Files

```
Sources/iOS/iOSSafariContentBlocker/
  ContentBlockerRequestHandler.swift        vends the JSON via NSItemProvider
  ContentBlockerRules.json                  the Docker spike rule list
  Info.plist                                extension point + principal class
  iOSSafariContentBlocker.entitlements      App Group group.com.getbored.ios
  PrivacyInfo.xcprivacy                     no tracking, no collected data

Sources/iOS/App/
  SafariContentBlockerState.swift           clear lease → getState → reload → publish flag
  AppDelegate.swift                         refresh at launch, on foreground, and on a 60 s foreground timer

GetBoredIOS.xcodeproj/project.pbxproj       registers + embeds the appex
```

The appex is registered as a real target **and** embedded, following the
`iOSFlowInspector` pattern: `PBXTargetDependency` on `GetBored iOS`, plus an entry
in the `Embed App Extensions` copy phase.

Historical note: the earlier spike's `SafariChildRegistrationExtension` and
`SafariAppProxyProvider` targets were removed from the project. The Content
Blocker replaces the Safari Web Extension + App Proxy approach for Safari
filtering, so those experiments were not kept around.

---

## Exact rules JSON

`Sources/iOS/iOSSafariContentBlocker/ContentBlockerRules.json`, verbatim:

```json
[
  {
    "trigger": {
      "url-filter": ".*"
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": "^https?://([a-z0-9-]+\\.)*docker\\.com([:/].*)?$",
      "resource-type": ["document", "top-document", "popup"]
    },
    "action": {
      "type": "ignore-previous-rules"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "if-top-url": ["^https?://([a-z0-9-]+\\.)*docker\\.com([:/].*)?$"],
      "resource-type": [
        "image",
        "script",
        "style-sheet",
        "font",
        "media",
        "raw",
        "svg-document",
        "fetch",
        "websocket",
        "ping"
      ]
    },
    "action": {
      "type": "ignore-previous-rules"
    }
  }
]
```

### Why it is shaped this way

- **Rule 1** blocks every URL. This is the default-deny baseline.
- **Rule 2** re-allows *navigations* whose own URL is Docker: `document`,
  `top-document`, `popup`. Matching on the request URL (not `if-top-url`) is what
  makes typing `docker.com` in the address bar work.
- **Rule 3** re-allows *subresources* — but only when the **top-level** page is
  Docker, via `if-top-url`. Docker may load CDN and third-party asset hosts that
  are not under `docker.com`, so a URL-only carve-out would not fully render it.
- **Rule 3 deliberately omits** `document`, `top-document`, `child-document`, and
  `popup`. Without that omission, *any* page — including a blocked site — could
  load a blocked document inside an iframe or open it as a popup just by sitting
  inside a Docker top-level context. Subframes inside Docker stay blocked; that
  is the contract, and it is the intended narrow spike behaviour.

The `^https?://([a-z0-9-]+\.)*docker\.com([:/].*)?$` anchor matters. It matches
`docker.com` and `www.docker.com` (and any real subdomain), but **not**
`evildocker.com` (no dot before `docker`) and **not** `docker.com.evil.com` (the
trailing `([:/].*)?$` refuses a `.` after the host).

`url-filter` matching is case-insensitive by default in WebKit, so
`DOCKER.COM` is covered without `url-filter-is-case-sensitive`.

### `[]` is never vended

An empty rule list is not merely unhelpful, it is **invalid**: WebKit rejects `[]`
with `WKErrorDomain error 6` (verified locally via
`WKContentRuleListStore.compileContentRuleList`). `ContentBlockerRequestHandler`
therefore has exactly one failure path, `vendNothing`, which calls
`completeRequest(returningItems: nil)`. Returning `nil` leaves Safari on its
previously compiled list rather than handing it an empty one.

The handler enforces this at runtime, not just by convention: it decodes the
bundled file and only vends when the result is a **non-empty JSON array**. A
missing file, an unreadable file, malformed JSON, or a literal `[]` all fall
through to `vendNothing`.

---

## How the enabled lease is written

`SafariContentBlockerState.refresh()` is the only writer of the
`safariContentBlockerEnabled` / `safariContentBlockerEnabledAt` pair. It is called
from `AppDelegate`:

- `application(_:didFinishLaunchingWithOptions:)` — launch.
- `applicationDidBecomeActive(_:)` — every foreground, which is the first moment
  the app can observe a toggle the user made in Settings.
- a repeating foreground timer (60 s) that keeps the lease fresh while GetBored is
  in the foreground.

The flag is a **short-lived lease**, never a permanent on/off signal. Resolution
is fail-closed by construction:

1. Every `refresh()` starts by writing `safariContentBlockerEnabled = false` and
   removing `safariContentBlockerEnabledAt` **before** the async
   `getStateOfContentBlocker` call. The in-flight window therefore fails closed.
2. `getStateOfContentBlocker` then resolves:

   | `getStateOfContentBlocker` outcome | Result |
   | --- | --- |
   | `error != nil` | `false`, no lease |
   | `state == nil` | `false`, no lease |
   | `state.isEnabled == false` | `false`, no lease |
   | `state.isEnabled == true` | proceed to reload |
3. Only when the state is enabled does `refresh()` call
   `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)`. The flag is
   **not** published before this succeeds — the first enable must not hand Safari
   flows to a blocker with no compiled rules.
4. Only a `reloadContentBlocker` completion with `error == nil` writes
   `safariContentBlockerEnabled = true` **and**
   `safariContentBlockerEnabledAt = Date().timeIntervalSince1970` (seconds since
   1970, `Double`). Any reload failure — or an unreadable App Group suite — leaves
   the flag `false` with no lease.

The reader in `FlowInspector` only honors the skip when the flag is a **real**
`Bool` `true` (rejecting `String`/`NSNumber` coercion) **and** the lease
timestamp is a fresh `Double`/`NSNumber` within
`safariContentBlockerLeaseInterval` (120 s). Missing, wrong-typed, or stale
values keep the Network Extension filtering Safari.

---

## Enabling the blocker on a device

The extension is **off by default** after install. iOS requires an explicit user
toggle; there is no API to enable it programmatically.

1. Install the app (`make install`, or `make install-release` for the 13 mini).
2. Open **GetBored** once and let it finish launching. This registers the appex
   with the system and writes the initial `safariContentBlockerEnabled = false`
   (no lease).
3. Open **Settings → Safari → Extensions**.
4. Under **Content Blockers**, find **GetBored Content Blocker (SPIKE)**.
   - Not listed? Force-quit GetBored, reopen it, and check again. A freshly
     installed appex can take a launch or two to appear.
5. Toggle it **on**.
6. Return to **GetBored**. `applicationDidBecomeActive` fires, re-reads the state,
   reloads the rules, and writes `safariContentBlockerEnabled = true` plus a fresh
   `safariContentBlockerEnabledAt` lease timestamp.
7. In Safari, load `https://www.docker.com` (should render) and any other site
   (should be blocked by the Content Blocker).

To turn it off, repeat step 5 and return to GetBored so the flag is rewritten to
`false`.

### Verifying the lease

```sh
# From a paired-device shell / simulator container, inspect the App Group suite:
defaults read "$APPGROUP/Library/Preferences/group.com.getbored.ios.plist" \
  safariContentBlockerEnabled safariContentBlockerEnabledAt
```

The app logs every resolution under subsystem `com.getbored.filter`, category
`SafariContentBlockerState`:

```sh
log stream --predicate \
  'subsystem == "com.getbored.filter" AND category == "SafariContentBlockerState"'
```

After step 6 expect `reloadContentBlocker succeeded` then
`safariContentBlockerEnabled = true` with a fresh lease timestamp, in that order.
A missing/stale `safariContentBlockerEnabledAt` means the skip is closed.

---

## Known spike limitations

These are accepted for the spike and must be resolved before production.

1. **Bounded fail-open window (lease).** If the user disables the extension in
   Settings and never returns to GetBored, the last `true` lease ages out after
   `safariContentBlockerLeaseInterval` (120 s) and the Network Extension resumes
   filtering Safari. iOS offers no callback for a content-blocker toggle, so the
   window is bounded by the lease rather than closed. Launch + foreground + the
   60 s foreground timer keep the lease fresh while the app is active; once
   GetBored can no longer confirm the extension state, the skip fails closed.
2. **Hardcoded Docker.** The rule list is a static bundled file. Nothing reads the
   whitelist, and the handler has no App Group dependency.
3. **Subframes stay blocked.** `child-document` is intentionally omitted from
   rule 3, so iframes on Docker are blocked. Fine for the spike, wrong for a real
   allow-list.
4. **No `if-domain`/`unless-domain` usage.** The spike expresses the allow-list
   with `url-filter` + `if-top-url` only.
5. **Provisioning.** `com.getbored.filter.safaricontentblocker` must remain in
   the App ID / provisioning profile with the App Group capability. Signed Debug
   device builds and embedded-binary validation now pass; App Store provisioning
   is still unverified.

---

## Local verification performed

```sh
# Clean, signed device build of the whole app and its embedded extensions.
make build-device
# → BUILD SUCCEEDED

make preflight
# → preflight ok: GetBored.app frameworks satisfied
```

Post-build checks on the produced bundle:

- `GetBored.app/PlugIns/iOSSafariContentBlocker.appex` exists alongside
  `iOSFlowInspector.appex` and `iOSBlockHandler.appex`.
- appex `Info.plist`: `CFBundleIdentifier = com.getbored.filter.safaricontentblocker`,
  `NSExtensionPointIdentifier = com.apple.Safari.content-blocker`,
  `NSExtensionPrincipalClass = iOSSafariContentBlocker.ContentBlockerRequestHandler`.
- `ContentBlockerRules.json` is present in the appex bundle.
- The rule JSON compiles under `WKContentRuleListStore.compileContentRuleList`
  (3 rules), and `[]` is confirmed rejected by the same API.

No unit tests were added, per the spike contract.
