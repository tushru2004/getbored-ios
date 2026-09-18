# XR SmartDNS: 25 selected test websites

Recorded: 2026-09-18.

These domains were selected for the XR SmartDNS static allow layer: 15 programming,
5 Austrian banking, and 5 public-transport sites. Each entry matches the exact
hostname and its dot-delimited subdomains.

## Programming

1. developer.apple.com
2. swift.org
3. swiftpackageindex.com
4. developer.mozilla.org
5. typescriptlang.org
6. react.dev
7. reactnative.dev
8. nodejs.org
9. python.org
10. docs.github.com
11. npmjs.com
12. jetbrains.com
13. docs.docker.com
14. kubernetes.io
15. postgresql.org

## Banking

16. sparkasse.at
17. raiffeisen.at
18. bankaustria.at
19. easybank.at
20. bawag.at

## Public transport

21. oebb.at
22. wienerlinien.at
23. vor.at
24. westbahn.at
25. wlb.at

## Scope and matching

- These are 25 selected entries, not necessarily 25 net-new permissions.
- Existing allowlists remain in place. Air reported that the legacy generated
  allowlist already includes broader `apple.com`, `github.com`, and `docker.com`
  entries; the narrower documentation entries above do not restrict those.
- Static allow matching precedes classifier/cache handling. Other domains remain
  subject to existing rules and classifier behavior; existing static blocks remain.
- Match `host == domain` or `host.endsWith('.' + domain)` after hostname
  normalization, not an unrestricted string suffix.
- Different-root redirects, CDNs, and sign-in dependencies are not implicitly
  covered by these entries. Full website or banking-login functionality has not
  been established by allowing the primary domain.
- No iOS content-filter rules were changed as part of this recorded update.

## Deployment and verification reported by Air Codex

Bridge message 8 reported deployment of Worker version
`65dda446-715a-4d48-800e-4b8685fcaf5f` without rebuilding or restarting the
classifier container or changing its prompt/rule order.

Reported live checks:

- All 25 base domains and 25 synthetic child hostnames returned `allow/static_allow`.
- A-record DoH queries for all 25 base domains returned `NOERROR` with answers.
- `youtube.com` remained `static_block`.
- XR's `com.getbored.iphone.dns-gateway-profile` was present and active alongside
  the existing XR Focused GetBored Filter profile.
- One unrelated classifier check was still pending at the time of that message.

These results are Air's report, not an independent device verification by this
session. They establish reported Worker/DNS checks and profile state, not Safari
end-to-end enforcement or complete third-party dependency coverage.

Air's implementation-side documentation:
`getbored-supervision/poc/xr-smartdns-worker/developer-test-sites.md`.
