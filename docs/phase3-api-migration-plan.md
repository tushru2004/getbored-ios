# Phase 3 — iOS off CloudKit, onto the GetBored API

Status: PLAN (2026-07-17). Implements against the Kotlin/Ktor backend from
`getbored-mac-ios-admin` (issue tushru2004/GetBored#157). Targets staging
(`admin.staging.getbored.online`) during development; production promote at
the end.

## Why the surface is small

A full audit of this repo found exactly ONE file touching CloudKit:
`Sources/iOS/App/FilterStatusModule.swift` (the `FilterStatus` RN module),
via four bridge methods: `current` (accountStatus half), `registerDevice`,
`currentDeviceRegistration`, `syncFilterLists`. Everything downstream is
already CloudKit-agnostic:

- Rules reach the FilterDataProvider extension through App-Group
  `UserDefaults` (`IOSRuleStore`, `group.com.getbored.ios`) — the extension
  needs **zero changes**.
- The JS bridge surface (`FilterStatusBridge`, hooks, screens) keeps its
  five method signatures — **no TS changes strictly required**.
- `KeychainDeviceID` already provides a durable per-device UUID.

There is no auth of any kind in the app today (no SIWA, no tokens); the only
gate is `CKContainer.accountStatus`. That is the one genuinely NEW piece.

## Identity model (the one real design decision)

Two ids exist after this migration:

1. **Server device id** — minted by `POST /api/devices`, the id the web
   admin assigns blocklists to and the id `GET /api/policy?deviceId=` wants.
2. **Local hardware id** — the existing Keychain UUID. Kept only as a
   stable "have I registered before?" marker.

The CloudKit-era trick of matching assignment by record name
(`DeviceRegistration-<id>-<env>`) disappears: the server does the matching.
iOS stores the **server** device id in the Keychain after registration and
uses it for every policy pull. List-merging logic in the app
(`applyDecodedFilterLists`'s union/dedupe/mode resolution) is **deleted** —
`GET /api/policy` returns the already-merged snapshot, computed server-side
by the same rules (whitelist-wins, ordered-unique).

Auth: native Sign in with Apple (`ASAuthorizationController`) → send
`identityToken` + `rawNonce` to the existing `POST /auth/apple` (body
delivery → Bearer token), session JWT stored in the Keychain. The same
sign-in also captures the `authorizationCode` — required later for account
deletion (TN3194: exchange at Apple's `/auth/token`, revoke at
`/auth/revoke`).

## Increments

### Backend (getbored-mac-ios-admin)

> **Status (2026-07-17): B1–B5 all done and verified on staging.** B3
> added a V7 migration (`user_identities.apple_client_id`) beyond this
> plan: Apple's `/auth/revoke` needs a client secret minted for the same
> client id the grant belongs to, so the V6 token alone wasn't revocable.
> B2's remaining proof is one real sign-in on staging web to observe a
> captured refresh token. B5 confirmed the wire contract with no changes.

**B1 — Revocable sessions.** `sessions` table (id/jti, user_id, created_at,
revoked_at); mint stamps `jti`; the `jwt("session")` validate step checks
the row isn't revoked (one PK read, same cost as the entitlement gate).
`POST /auth/logout` revokes the presented session's row (today it only
clears the cookie). Enables account deletion to kill all sessions, and
"sign out everywhere" later.

**B2 — Apple token capture.** `POST /auth/apple` accepts optional
`authorizationCode`; backend exchanges it (client secret = ES256 JWT signed
with the SIWA `.p8` key) and stores the resulting Apple `refresh_token` on
`user_identities`. New env: `APPLE_TEAM_ID`, `APPLE_KEY_ID`,
`APPLE_PRIVATE_KEY`. Exchange failure must NOT fail sign-in (log + proceed;
revocation then does best-effort per TN3194).

**B3 — `DELETE /api/account`.** Revokes the stored Apple refresh token
(best-effort), revokes all sessions (B1), deletes the user's rows (devices,
blocklists + children, identities, user) in one transaction, clears the
cookie. Exempt from the entitlement gate (a lapsed user must still be able
to delete their account — same reasoning as `/api/me`).

**B4 — Heartbeat for free.** `GET /api/policy` updates the device's
`last_seen_at` as a side effect. No new endpoint; the admin's "Last seen"
becomes real the moment iOS starts pulling.

**B5 — Wire contract check.** Confirm `PolicySnapshot` carries everything
`IOSRuleStore.applyFilterListSnapshot` needs (entries, exceptions,
allowedApps, blockedApps, mode). Add `systemVersion`/`buildConfiguration`
to `DeviceInput`? — NO: keep the API lean; iOS folds them into the existing
free-text `model`/`appVersion` fields ("iPhone11,8 · iOS 18.2").

### iOS (this repo)

**i1 — API client + config.** Small `URLSession` client in
`Sources/iOS/App/` (no dependency): base URL by build config (`#if DEBUG` →
staging, else prod), Bearer header injection, typed errors distinguishing
401 (signed out), 402 (subscription lapsed), network. New Keychain entries:
session token, server device id (extend `KeychainDeviceID` into a small
keychain store; rename the "cloudkit" account constants while at it).

**i2 — Sign in with Apple.** New native module (`Account`):
`ASAuthorizationController` flow with SHA-256 nonce (same contract the web
uses), sends identityToken + rawNonce + authorizationCode to
`POST /auth/apple`, stores the session token. Exposes
`signIn()/signOut()/currentAccount()` to JS; a minimal RN sign-in card on
the home screen gates the register/sync cards. `signOut()` calls
`POST /auth/logout` (revokes server-side after B1) and clears the Keychain.

**i3 — Device registration over REST.** `registerDevice` →
`POST /api/devices` (name/model/appVersion), store returned server id;
subsequent calls with a stored id → `PUT /api/devices/{id}` (re-register =
update). `currentDeviceRegistration` → `GET /api/devices/{id}`. The
CloudKit zone dance, record fetch-or-create, and env-suffixed record names
all go away. JS promise shapes preserved.

**i4 — Policy pull.** `syncFilterLists` → `GET /api/policy?deviceId=` →
`IOSRuleStore.applyFilterListSnapshot(...)` on the main queue, exactly as
today. Delete `CloudFilterList`, the pagination cursor machinery, and the
client-side merge. Semantics preserved: empty-but-owned snapshot still
applies (clearing rules when the admin unassigns everything).

**i5 — Status + failure semantics.** `current()`: `icloudAvailable` is
replaced by `signedIn` (Keychain session presence; JS type gains the field,
old one kept temporarily as its alias to avoid a lockstep TS change).
Policy fetch 401 → surface signed-out state, keep existing rules. Policy
fetch **402 → apply an EMPTY snapshot (filter stops) + surface
"subscription required"** — implements the agreed lapse-stops-filtering
product decision. Network failure → keep existing rules, show error (same
as CloudKit failures today).

**i6 — CloudKit removal (cutover for iOS).** Delete the `import CloudKit`,
`CloudFilterList`/`DeviceRegistration` CK extensions, accountStatus gates;
strip `iCloud.com.getbored.sync` entitlements from App, iOSFlowInspector,
iOSBlockHandler; leave `getbored-core`'s CloudKit constants for the macOS
shell (they're unused by iOS after this). `cloudkit/schema.ckdb` stays
until the container is truly retired (Phase 4).

## Order & rationale

B1 → B2 → B3 land first (backend auto-deploys to staging; each verifiable
by curl). Then i1 → i2 → i3 → i4 → i5 as one iOS arc — the app compiles and
runs after each increment, with CloudKit paths intact until i6 flips them
out. i6 last, after an XR end-to-end pass: sign in → register → assign a
list in the web admin → sync → extension blocks the site.

Hard swap, no feature flag: the only current user is the founder's XR;
coexistence machinery would be pure cost.

## Prerequisites (Tushar, Apple portal — ~5 min)

1. **SIWA key**: Certificates, Identifiers & Profiles → Keys → “+” →
   enable "Sign in with Apple" → download the `.p8` (ONE download only —
   store it safely), note the Key ID and Team ID (`3A3AVFF22Q`). Needed
   from B2 on.
2. Nothing else: the bundle id `com.getbored.filter` already has the SIWA
   capability (enabled during Phase 2) and is already in the backend's
   `APPLE_AUDIENCES`.

## Explicitly out of scope

- macOS shell / CloudFront admin off CloudKit (Phase 4).
- Stripe (Phase 5) — the 402 handling in i5 is where its UX will hang.
- Push/background sync — pull-on-tap stays, per the openapi "Manual pull,
  no push" contract.
- Whitelist mode on device — `IOSRuleStore.decodedFilterMode()` keeps
  coercing whiteList→blockSpecific (v1 block-mode-only), unchanged.

## App Review coverage (why this phase unblocks submission)

- Account creation in-app → account **deletion** in-app: i2 + B3
  (Guideline 5.1.1(v)).
- SIWA token revocation on deletion: B2 + B3 (TN3194).
- Filter functionality without iCloud dependency: i3–i5.
