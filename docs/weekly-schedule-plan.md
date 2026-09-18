# Weekly list scheduling — staging implementation plan

Tracking: https://github.com/tushru2004/GetBored/issues/178

## Outcome

Add Sites → Apps → When → Protection → Devices. When offers All the time or
Weekly schedule for the current list. Each weekday supports multiple intervals.
Scheduling controls enforcement, independently of editing protection.

During an interval, an Allow List allows its configured sites and a Block List
blocks its configured sites. Outside intervals that list contributes no
restrictions. Existing system/Apple exceptions remain intact. Other active lists
continue to apply according to the existing policy-combination rules.

## Ownership and sequence

1. Root confirms the shared wire contract after backend/iOS inspection.
2. Backend worker adds validation, persistence, and complete offline policy sync.
3. iOS worker adds local schedule evaluation and boundary handling.
4. Pi agent adds the When step, keeping the staging dashboard's existing design.
5. Root reviews changes, builds, and coordinates manual integration checks.
6. Commit reviewed changes and deploy dashboard/API to staging only. Verify
   staging versions and leave production unchanged. iOS device verification is
   separate from web/API deployment.

## Confirmed contract

`schedule: {version: 1, mode: "always" | "weekly", timezone: "Europe/Vienna",
intervals: [{weekday: 1, start: "14:00", end: "18:00"}]}`

- ISO weekday numbers: Monday 1 through Sunday 7.
- Explicit persisted IANA timezone, initially suggested from the browser.
- Start inclusive, end exclusive; local wall-clock schedule follows timezone DST.
- Initially same-day intervals only (00:00 through 23:59); reject
  reversed/zero-length and overlapping intervals. Overnight windows and a 24:00
  end boundary are not supported in this first version.
- Missing schedule remains All the time. Empty weekly schedule is inactive.
- Schedule edits obey existing password/commitment authorization.
- Confirm old-client capability handling before staging deployment.

The device opts into `/api/policy?policySchemaVersion=2`, which supplies ordered
   full list records. The server records device support and rejects weekly
assignments to incompatible devices. Legacy v1 responses remain unchanged for
unscheduled lists; an incompatible request for a scheduled assignment gets an
explicit error, not a misleading flattened policy. The dashboard/API deployment
capability is `blocklists.weekly-schedule.v1`.

Active lists retain existing combination semantics: whitelist wins, with ordered
unique union of rule arrays. Mixed-mode precedence is not redesigned here.

New flows are evaluated locally even with the app closed. Exact revocation of
every already-open connection at a schedule boundary is NOT yet guaranteed by
the current Network Extension design. This limitation must remain visible in
staging acceptance and cannot be represented as completed hard-cutoff support.

## Acceptance checks (no new unit tests)

- Verify All the time and Weekly create/read/update round trips on staging.
- Exercise both list modes before, within, and exactly at the end of an interval.
- Verify Monday–Sunday mapping, explicit timezone, DST, empty weekdays, and
  invalid/overlapping interval rejection.
- Confirm offline evaluation uses the synchronized full policy, not only the
  last server-calculated active state.
- Confirm schedule transitions do not require foregrounding the app. Investigate
  ongoing-connection re-evaluation and document any platform limitation.
- Preserve normal system/Apple allow rules and native Safari support resources.
- Confirm existing unscheduled policies and protected-list authorization work.
- Check dashboard navigation, interval edits, and five-step rail manually.
- Backend compilation, TypeScript build, unsigned iOS Release build, diff review.

## Boundaries

No production promotion, App Store submission, new unit tests, or real device
installation without identifying the target and coordinating with the user.
The pre-existing App Store notes draft and other unrelated files are preserved.
