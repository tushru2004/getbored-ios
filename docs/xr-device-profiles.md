# XR device profiles

## Purpose: development under restrictions

Development devices are deliberately restricted too. The developer should be able to build, install, and test GetBored while remaining subject to device and browsing restrictions; a dev device is not an unrestricted escape from the policy.

The two companion profiles enforce that intent:

- **Dev Restrictions** limits device changes and available apps while preserving the access needed to develop and install builds.
- **Smart DNS / DNS Gateway** decides which websites are allowed under the development-use policy, using classification for domains that are not already covered by rules. Sites outside that policy remain blocked even on the developer's test phone.

These profiles are part of the normal development environment, not disposable test fixtures. Preserve them during development and diagnose policy failures rather than removing the restrictions to make a test pass. The native GetBored content filter remains a separate enforcement layer for the app's whitelist feature.

This note describes the existing profiles restored on the test iPhone XR on 2026-09-14. It is not a customer deployment or ADE/MDM enrollment guide.

## Source of truth

Profile templates live in the sibling `getbored-supervision` repository under `Config/`. Edit those templates rather than creating copies in this repository. On Air the repository is `~/repos/getbored-supervision`; use the matching checkout on Pro when available.

| Profile | Template in getbored-supervision | Installed profile identifier |
| --- | --- | --- |
| XR Focused GetBored Filter | `Config/xr-focused-getbored-filter.mobileconfig` | `com.getbored.advance.profile` |
| GetBored DNS Gateway | `Config/xr-focused-dns-gateway.mobileconfig` | `com.getbored.iphone.dns-gateway-profile` |
| XR Focused Dev Restrictions | `Config/xr-focused-dev-restrictions.mobileconfig` | `com.getbored.iphone.restrictions-profile` |

Device: iPhone XR, UDID `00008020-0004695621DA002E`.

## What each profile does

### Native content filter

The GetBored Filter profile enables the native iOS content filter used by this app. The whitelist document/socket implementation uses native Safari BrowserFlows and SocketFlows; it does not depend on Safari extension domain registration or a Safari App Proxy profile.

The accepted whitelist behavior checks document URLs directly against policy and permits shared Safari resource connections after a user-approved document opens. There is no 90-second resource expiry. Unrelated Safari background resource traffic is an accepted limitation. Embedded documents still undergo the direct document check: a YouTube iframe on an approved AWS article was blocked because `www.youtube-nocookie.com` was not directly approved. Embed inheritance is deferred.

### DNS Gateway

The DNS profile configures managed DNS over HTTPS with `ProhibitDisablement=true`:

- Payload type: `com.apple.dnsSettings.managed`.
- Resolver: `https://xr-smartdns.tushru2004.workers.dev/dns-query`.
- Gateway source: `getbored-supervision/poc/xr-smartdns-worker`.

The gateway applies its own domain policy. Static/system rules and heuristics precede cached classifier decisions. Unknown domains are provisionally blocked while queued classification runs. The checked configuration uses a container-backed Codex classifier; inspect the current worker configuration when troubleshooting rather than assuming the model is fixed forever.

DNS and the native whitelist are separate gates. A native socket allowance cannot overcome a DNS denial. A DNS allowance does not whitelist the website for Safari document navigation. Do not remove the DNS profile merely to make native-filter tests pass; identify which layer made the decision.

Live check on 2026-09-14: `magenta.at` received `source=classifier`, allow/neutral (telecom), with a container log recording one web search. `britannica.com` received `source=classifier`, block/distraction under the configured encyclopedia rule. Actual DoH A responses were respectively NOERROR with an answer and NXDOMAIN. These are timestamped observations, not permanent overrides or a guarantee about all classifications.

### Dev Restrictions

The focused restrictions profile keeps development access while limiting device changes:

- Allows development app installation, but disables UI App Store installation, marketplace installation, and web distribution installation.
- Disables app/system-app removal, account and cellular-plan/eSIM changes, device erase, Screen Time enabling, enterprise app trust, notification changes, device renaming, wallpaper changes, hotspot changes, and iCloud Private Relay.
- Allows AirDrop, Bluetooth changes, passcode/biometric changes, VPN creation, and UI configuration-profile installation; forces automatic date/time.
- App allowlist: Phone, Messages, Safari, Settings, Camera, Photos, Clock, Calculator, and `com.getbored.filter`.
- Does not set a host-pairing restriction in this focused template.

The DNS and restrictions profiles use removal protection and a removal password. Do not commit passwords or password-bearing generated profiles.

## Installation and verification

Use the existing scripts and documentation in `getbored-supervision` as the installation reference. Scope operations to the requested profiles: the broad `scripts/xr-focused-profiles reinstall` workflow also touches the content filter and app proxy, so it is not appropriate for restoring only DNS and restrictions unchanged.

Create restricted temporary profile copies with the existing removal password substituted for the template placeholder. Never print the password, place it in shell history, or send it through agent messages. Delete the temporary password file and generated copies after transfer/verification.

A matching supervision identity can support silent installation. During the Air reinstall, Configurator did not accept the local identity; `pymobiledevice3 profile install` downloaded each profile for the user to approve in Settings. A successful download is not proof of installation. Install one at a time and verify the profile list:

```sh
pymobiledevice3 profile list --udid 00008020-0004695621DA002E
```

Check the expected identifiers and `ProfileManifest` entries with `IsActive=true`. User-facing location: Settings → General → VPN & Device Management.

Verification on 2026-09-14: native filter and DNS Gateway were confirmed installed/active on Air. After reconnection, the Pro agent also confirmed Dev Restrictions installed and no App Proxy profile present. Recheck the current profile list when troubleshooting rather than treating this historical snapshot as live state. Temporary password and generated profile copies on Air were deleted. No Safari App Proxy or additional webcontent allowlist profile was installed in this restoration.

## Whitelist verification with these profiles

Keep the profiles installed, use the XR Debug build, and record DNS versus native-filter evidence separately. Confirm an approved AWS page loads, fresh resource connections remain permitted beyond 90 seconds, and direct navigation to unapproved `magenta.at` / `www.magenta.at` remains restricted. Restore any Inspector cache setting after automation. The Debug-build installation and native runtime verification are separate from installing these profiles.

## SmartDNS logs in the existing Pro dashboard

On Pro, run the existing command:

```sh
logs-dashboard
```

This starts the existing Loki/Grafana stack and checks the SmartDNS receiver. Grafana opens on Pro at `http://127.0.0.1:43534`. In Explore, select Loki and query:

```logql
{component="smartdns"} | json
```

To inspect a specific domain:

```logql
{component="smartdns"} | json | host="d2c.aws.amazon.com"
```

The existing native iOS logs remain available under `{component="ios"}`. Compare these with SmartDNS events to distinguish DNS policy decisions from native document/socket filtering.

### Where collection runs

- **Air** runs a login LaunchAgent, `com.getbored.smartdns-log-collector`, which subscribes to existing `xr-smartdns` logs using `wrangler tail --format json` and the existing Air Cloudflare login.
- **Pro** receives sanitized events in Loki over the private-network endpoint `http://100.84.125.103:3100/loki/api/v1/push`. This address is Pro, not Air.
- Pro's `logs-dashboard` function calls `dashboard/smartdns/start.sh` in the sibling `getbored-supervision` repository after starting the stack. No separate manual collector startup is needed during normal use.
- Air must be awake and logged in, and Pro must be reachable with Loki running. There is no Pro-side Cloudflare login requirement and no credential transfer between Macs.

Implementation and runbook: `getbored-supervision/dashboard/smartdns/` (`collector.py`, `install-air.py`, `start.sh`, `README.md`). Air collector state and bounded sanitized spool: `~/Library/Application Support/GetBored/SmartDNSLogs/`; `status.json` reports received/pushed counts and delivery status. The installer is for Air; the receiver hook is for Pro.

### Read-only scope and limits

The collector only subscribes to existing logs. It does not deploy or modify SmartDNS, query DNS to trigger classification, clear caches, create overrides, restart the classifier, or change gateway policy. It reuses existing OAuth credentials only for tailing; those credentials have broader permissions, so this is read-only collector behavior, not a separately scoped read-only credential.

Known structured events retain domain, action, category, decision source, classifier backend, search count and timing when emitted. Request headers, cookies, client IPs, full URLs, free-form reasons, raw exception bodies and stacks are discarded. Failure records retain `error_present` instead of raw error text. The gateway does not currently emit every desired detail: an allow decision alone is not proof of a successful upstream DNS response, and missing response codes cannot be reconstructed from these events.

Events retain source time in `timestamp_ms`; Loki timestamps use ingestion time so buffered events can be delivered after downtime. The buffer holds at most 10,000 sanitized events and discards oldest entries when full. Logs missed while the Cloudflare tail subscription is disconnected cannot be replayed. Do not claim historical events predating collection are available.

Verified on 2026-09-14: `logs-dashboard` completed with the new receiver hook, and real SmartDNS DNS-query and container-classifier events reached Pro Loki. No gateway mutation or synthetic DNS probe was used to generate this evidence.
