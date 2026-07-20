# Research: Selling Pre-Supervised iPhones

Research notes on the legality and viability of selling used iPhones that are
pre-supervised (Apple Configurator / MDM) — e.g., as a hardware companion to
the GetBored filtering product.

*Researched 2026-07-03. Not legal advice — run the license questions past an
attorney before committing to a go-to-market model.*

## TL;DR

- **Selling the phone itself is legal.** No statute prohibits selling a
  supervised iPhone; first-sale doctrine covers the hardware, and supervision
  is just a device state.
- **The risk is contractual, not criminal.** Supervising devices specifically
  to sell them to third parties sits outside the Apple Configurator license
  grant ("internal technology management within your company or
  organization"). Apple's remedy is license/account termination, not legal
  action against buyers.
- **Commercial precedent exists and Apple has not enforced against it** — but
  it is concentrated in the kosher-filter ecosystem, and the durable players
  use ABM + MDM enrollment (organization "owns or controls" the devices),
  not bare tethered Configurator supervision.
- **For GetBored, the exposure is inverted:** pure MDM-service businesses
  never touch App Review; we ship an App Store app, so guideline 5.5 applies
  to us in a way it never applies to them. Keep any device-management
  business cleanly separable from the App Store app.

## 1. What the Apple Configurator SLA actually says

Source: [Apple Configurator Software License Agreement (PDF)](https://www.apple.com/legal/sla/docs/AppleConfigurator.pdf)

Load-bearing clauses:

- **Section 2.C.1 — internal-use scope.** "You may use the Apple Software
  only with supported Apple-branded products … and solely for purposes of
  internal technology management within your company or organization."
  Supervising inventory phones to sell to consumers is arguably not internal
  technology management.
- **Section 2.E — no service-bureau use.** You agree "not to use or offer the
  Apple Software, or any of its functionality, to provide service bureau …
  or other similar types of services to third parties." Supervision-as-a-
  service for customers is close to exactly this.
- **Section 2.C.3 — end-user consent.** You must "have all the necessary
  rights and consents from your end-users" for supervision and comply with
  privacy/data-collection laws. A buyer who knowingly purchases a supervised
  phone and consents in writing largely covers this — but consent must be
  explicit and disclosed.

Consequences of breach: Apple can terminate the Configurator license /
ABM account. This is a contract dispute with Apple, not a legal issue for
the buyer.

### 1b. The ABM agreement is stricter than the Configurator SLA

Extracted from the [Apple Business Manager Agreement (US PDF)](https://www.apple.com/legal/enterprise/apple-business-manager/abm-us.pdf):

- **"Authorized Devices"** — "Apple-branded devices that are owned or
  controlled by You, have been designated for use by Authorized Users or
  Permitted Users only … For the avoidance of doubt, **devices that are
  personally-owned by an individual (e.g., 'BYOD' devices) are not
  permitted to be enrolled in supervised device management** (e.g.,
  configured with Device Enrollment Settings) as part of the Service,
  unless otherwise agreed by Apple in writing."
- **"Authorized Users"** — "employees and Contract Employees (or Service
  Providers) of (i) Your Institution and/or (ii) Your Institution's …
  wholly-owned subsidiaries … **no other parties shall be included in this
  definition without Apple's prior written consent**." (There is a request
  path: "You may request, and Apple may approve, in its sole discretion,
  other similar users.")
- **"Permitted Users/Entities"** — enumerated carve-outs only: vehicle
  dealerships, hotel properties, and Restricted App Mode deployments
  (e.g., point-of-sale iPads at customer sites).

Consequence: **selling ABM-supervised iPhones to consumers violates the
agreement's letter in both directions** — customer-owned ⇒ barred BYOD
supervised enrollment; seller retains title ⇒ designated for use by a
non-Authorized User. Consumer supervision via ABM is possible only as a
tolerated breach or with Apple's written consent. The Kosher iPhone's
years of operation demonstrate tolerance, not compliance. By contrast,
Configurator-only supervision (Models B/B-2) involves no ABM agreement at
all — only the softer §1 gray zone — and there is no account for Apple to
revoke.

(Related: Apple's sanctioned consumer MDM — the post-2019 guideline 5.5
parental-control apps like OurPact — uses *unsupervised profile-based*
enrollment on family devices, which is consistent with the BYOD-supervision
bar above.)

## 2. Practical properties of the two supervision routes

| | Tethered Configurator supervision | Configurator → ABM + MDM enrollment |
|---|---|---|
| Survives factory reset | **No** — buyer can erase/restore via Finder and supervision is gone | **Yes** — device re-enrolls on activation |
| Ongoing remote control after sale | No (unless paired cert retained) | Yes (MDM relationship) |
| License standing | Grayest — "internal management" stretch | Cleaner — org "owns or controls" devices at enrollment |
| Escape hatch for user | Any time (full erase) | [30-day provisional period](https://support.apple.com/guide/apple-business-manager/axm200a54d59/web) to release from ABM/supervision/MDM |

Notes:

- ABM is open to essentially any registered business with a D-U-N-S number.
- Apple explicitly documents [adding devices to ABM via Configurator even if
  not purchased from Apple or an authorized reseller](https://support.apple.com/guide/apple-business-manager/axm200a54d59/web).
- The 30-day provisional release window is Apple's own consent model for a
  user knowingly accepting management of a device they use. Customers who
  want the lockdown simply don't exercise it.
- Non-persistence of tethered supervision cuts both ways: weaker product
  (not tamper-proof) but stronger legality story (buyer is never locked out
  of full ownership).

## 3. Market landscape — who actually does this

**Mainstream "focus phone" brands are NOT supervised iPhones:**

- [Balance Phone](https://www.thebalancephone.com/) — Samsung Galaxy A16 with
  custom Balance OS.
- [Techless Wisephone](https://thephoenixspirit.com/2024/07/techless-wisephone-review/) —
  own Android-based hardware.
- Light Phone, Mudita, Punkt — own hardware.

**The real precedent is the kosher-phone ecosystem:**

- **The Kosher iPhone (Lakewood NJ / Monsey NY / Brooklyn) — the one vendor
  verified to have sold ABM+MDM supervised iPhones directly to consumers —
  but past tense.** Its search-indexed location pages stated every order
  "ships pre-configured from their Lakewood, NJ operations center, arriving
  in Apple's original packaging with MDM enrollment, Supervised Mode, chosen
  app whitelist, and the full KolBo portfolio already installed," and
  explicitly: "Factory reset doesn't help — the device re-enrolls in their
  MDM automatically" (reset-surviving re-enrollment ⇒ ABM device
  enrollment). However, thekosheriphone.com now 301-redirects to
  [kolbo.life](https://kolbo.life/), and the rebranded company **no longer
  sells phones**. Its FAQ ("[Is there a kosher
  iPhone?](https://kolbo.life/learn/kosher-phones-2026/)") states, verbatim:
  > Not as a certified device you can buy off a shelf — the certified-device
  > market is overwhelmingly basic phones and locked-down Androids, because
  > Apple's platform doesn't permit the deep removal that certification
  > requires. What a family with an existing iPhone can do is put a
  > protection layer on it: KolBo Secure covers "any iPhone or Android" with
  > tamper-resistant enforcement and a self-service portal, starting at
  > $14.99/month.

  **Decoding that answer:**

  - *"Not as a certified device you can buy off a shelf"* — "certified" here
    is **Jewish communal certification** (a hechsher for devices, the same
    concept as kosher food certification). KolBo's own guide defines it: "A
    phone becomes kosher when a body the buyer's community trusts certifies
    its lockdown — when someone whose standards you accept has verified that
    what was supposed to be removed or blocked actually is, **and stays that
    way**." The certifiers (verified 2026-07-03): **TAG** (Technology
    Awareness Group — America's most recognized; public
    approved/pending/non-approved model list, free walk-in offices, works
    with filter firms GenTech/Netspark/MB Smart), **Letaher** (Skver and
    other chassidishe communities, built on the Meshimer filter), **regional
    VAADim** (communal committees; Pom, Pom Classic, Tak S7 carry VAAD
    approval), **L'maaseh** (lmaaseh.tech, a newer entrant), and in Israel
    the **Rabbinical Committee for Communications** (certifies "Meushar"
    devices and controls kosher number ranges/SIMs at the network level —
    a 2026 Knesset bill codifies this). No iPhone appears on any of these
    lists.
  - *Nuance on what certification requires* — it is "a certification of
    **the block**, not a review of the phone" (KolBo FAQ). The bar is not
    literally "permanent OS-level removal" in every case; it is a verified
    lockdown that *stays locked*. The market spans system-level blocks
    verified by TAG (Qin F30 Kosher, TCL Flip 2, Wonder Phone) up to
    lockdown-as-the-OS platforms (MindOS, KosherOS Pixels "rebuilt by
    removal", Letaher-certified Waze-only Pixel 5s). iPhones fail this bar
    on two counts: the lockdown can't be made durable (any user can
    DFU/erase out of supervision), and certifiers can't flash or deeply
    verify a custom build the way they can on Android.
  - *"Apple's platform doesn't permit the deep removal that certification
    requires"* — the key admission, matching what §1/§2 conclude from the
    Configurator SLA and ABM agreement independently. On iOS nobody but
    Apple can modify the OS. The strongest available tools (supervision +
    MDM restrictions) **disable and hide** features — Safari, App Store,
    camera — but don't **remove** them. Every restriction is a policy layer
    on an intact OS, and a determined user can always escape via DFU
    restore/erase. Certification bodies won't certify "hidden but
    recoverable," so no iPhone can qualify.
  - *"put a protection layer on it: KolBo Secure… $14.99/month"* — KolBo's
    iPhone answer is the only one iOS allows: BYOD enrollment in their
    management layer, "tamper-resistant" rather than tamper-proof.

  **Why this matters for GetBored:** this is KolBo — the one company that
  actually *tried* selling pre-configured supervised iPhones under
  thekosheriphone.com — publicly explaining why they stopped. Their stated
  reason isn't legal risk or Apple enforcement; it's that iOS can't
  technically deliver what their market (certification-grade lockdown)
  demands. GetBored's market is different: the thesis is *friction*, not
  certification-grade removal. A supervised iPhone with password-gated
  removable profiles (Model B-2, §6) doesn't need to clear the bar KolBo
  failed — "hidden but recoverable with deliberate effort" is exactly the
  product, not a disqualifier.

  Current KolBo model: (a) license the KolBo software suite
  to kosher-device *manufacturers* (Android "Flagships"), and (b) **KolBo
  Secure** — BYOD supervision of customer-owned iPhones/Androids from
  $14.99/month via a self-service portal, marketed as "tamper-resistant by
  architecture" ("remove the management layer and the safeguard stays
  locked").
  *Evidence caveat:* the pre-configured-iPhone sales claims come from
  search-engine snippets of the now-redirected location pages; archive.org
  was unreachable to confirm them first-hand.
- Adjacent kosher-market sellers — [The Phone Gesheft](https://thephonegesheft.com/locations/monsey),
  [SafeCell](https://www.thesafecell.com/), [Kosher Signal](https://koshersignal.com/pages/contact-us) —
  sell filtered/kosher phones over the counter, but the full
  ABM+MDM+survives-reset architecture is only verified for the historical
  The Kosher iPhone offering.

**How KolBo "sells supervised devices" today without the ABM problem
(resolved 2026-07-03 by crawling kolbo.life/kolbofilter.com):**

- **The devices sold in kosher stores are Android** — KolBo's own
  [store directory](https://kolbo.life/learn/kosher-phone-stores/) lists
  Fig, Qin, Kyocera, LG, TCL. Android device-owner supervision / custom OS
  involves no Apple agreement at all, so the supervised-device *sales*
  happen entirely where the ABM bar doesn't exist. KolBo's "Flagships" are
  these Android devices running its licensed software layer.
- **For iPhones, KolBo sells no hardware.** KolBo Secure is BYOD-only via a
  "self-service portal"; enrollment mechanics are deliberately undisclosed
  (no mention of ABM, supervision, Configurator, or MDM anywhere public —
  "contact hello@kolbo.life"). A self-service iPhone flow with no ABM is
  almost certainly profile-based **unsupervised** MDM enrollment — the same
  architecture Apple blessed for parental-control apps in guideline 5.5.
  The "tamper-resistant / stays locked" copy most plausibly maps to
  removal detection + accountability, not a hard OS lock.
- **The one true consumer ABM-supervised-iPhone line (thekosheriphone.com)
  was discontinued in the rebrand.**

**⚠ Correction (2026-07-03, after WHOIS/archive investigation): The Kosher
iPhone was NOT a years-old business.** Domain registration dates:
thekosherphone.com 2026-01-20, thekosheriphone.com 2026-02-05, kolboapp.com
2026-02-08, kolbofilter.com 2026-03-25. The parent kolbo.life's first
archive.org capture is 2025-07-17. thekosheriphone.com has **zero
archive.org captures**, **no news coverage anywhere**, and no findable
forum/Reddit discussion — and by 2026-07 it already 301-redirects to
kolbo.life. So the "Kosher iPhone" was a **~5-month brand experiment** by
KolBo Products LLC (likely SEO-driven landing pages for a nascent
offering), not a long-tolerated business. What its existence actually
proves: someone publicly *marketed* consumer ABM-supervised iPhones for a
few months without visible Apple reaction — much weaker precedent than
"operated for years." The durable, genuinely old precedents in this space
are the supervision-*service* players: TAG/Netspark (in-person
supervision), OurPact (desktop-app supervision), Tech Lockdown (DIY
supervision) — see §7. No evidence of any Apple enforcement or lawsuit
against KolBo/The Kosher iPhone exists; the closest Apple resale lawsuit
on record is [Apple v. GEEP](https://www.foxbusiness.com/lifestyle/apple-lawsuit-selling-devices-recycle)
(a recycling contractor that resold devices it was hired to shred —
unrelated fact pattern).
- Searches for any other vendor (secular or religious) selling supervised
  iPhones to consumers in 2025–2026 return nothing — only enterprise MDM
  tooling. **The niche is empty.**
- [GenTech](https://www.gentechsolution.com/sign-up-ios/) and the
  [TAG network](https://tagatlanta.org/filters/) — supervision-based iPhone
  filtering as a service; TAG offices sell pre-approved devices via partner
  merchants. Kosher phone stores in Lakewood/Monsey routinely sell iPhones
  with the filter pre-applied.
- [Tech Lockdown](https://www.techlockdown.com/articles/dumb-phone-iphone) —
  secular equivalent, but sells supervision guides/config services for your
  own iPhone, not pre-supervised hardware.

Selling the phone *pre-supervised* (vs. supervising the customer's phone) is
a niche within that niche.

**Bottom line (as of 2026-07): no verified vendor — kosher or secular —
currently sells ABM+MDM supervised iPhones to consumers off the shelf.**
[Pinwheel](https://www.pinwheel.com/howitworks), Troomi, Gabb, and Bark
Phone are all Android with proprietary parental-management stacks. The one
company verified to have done it (The Kosher iPhone) has pivoted to BYOD
supervision of customer-owned iPhones plus licensing software to Android
manufacturers. Read on the pivot: selling supervised iPhone hardware was
viable enough to operate publicly for years without Apple enforcement, but
the business gravity pulled toward supervise-what-the-customer-owns —
lower inventory risk, recurring revenue, and cleaner "own or control"
standing. The pre-supervised-hardware slot is currently **empty**: either a
market gap or a signal that the model doesn't sustain a business.

## 4. Why Apple hasn't kicked them out

1. **They use the front door Apple built.** ABM + Configurator + MDM is the
   documented workflow. Their fleet is indistinguishable from any small
   business managing devices — nothing anomalous to detect.
2. **Consent keeps them inside Apple's consent *mechanics*, not its
   contract.** The 30-day provisional release window exists for a user
   knowingly accepting management — but per §1b the ABM agreement's letter
   still bars consumer supervised enrollment. Their operation was a
   tolerated breach, invisible and unenforced, not a compliant structure.
3. **Apple's only real enforcement chokepoint is App Review — and these
   businesses never cross it.** Restrictions ship as enterprise MDM payloads,
   not App Store apps.
*(Note: this section was written when The Kosher iPhone appeared to be a
years-old operation; per the §3 correction it ran only months. Points 1–3
and 5 still hold — they explain why Apple has no detection surface or
incentive — but the "tolerated for years" evidence is gone.)*

4. **The one crackdown proves the point.** 2018–2019: Apple removed consumer
   screen-time apps (OurPact, Mobicip, …) that distributed MDM profiles via
   App Store apps, right after launching Screen Time. After backlash,
   [Apple reversed in June 2019](https://developer.apple.com/news/?id=06032019j)
   and rewrote **guideline 5.5** to permit MDM "in limited cases, companies
   utilizing MDM for parental controls" with strict no-data-selling
   conditions ([MacRumors](https://www.macrumors.com/2019/06/04/apple-lets-parental-apps-use-mdm-strict-privacy/),
   [9to5Mac](https://9to5mac.com/2019/06/04/parental-control-mdm-apple/)).
   Lesson: enforcement happens at the App Store, and even there Apple ended
   up legitimizing consumer-consented MDM for self-control/parental use.
5. **No incentive.** Tiny market, paying and consenting customers, every
   kosher iPhone is an iPhone sale, and revoking a religious community's
   filtering infrastructure is a PR debacle with zero upside. Apple's 2019
   concern was privacy abuse (data harvesting via MDM), not consenting
   adults locking themselves down.

## 5. Implications for GetBored

- **Our exposure is the inverse of theirs.** We ship an App Store app, so
  App Review and guideline 5.5 apply to us directly. A pure MDM-service
  business has no App Review surface at all.
- If we ever pair the app with a supervised-device offering, copy the proven
  architecture: **ABM + MDM enrollment under a real business entity, explicit
  written customer consent, restrictions delivered as MDM payloads** — and
  keep the App Store app's functionality cleanly separable from the
  device-management business.
- Sales posture for pre-supervised hardware: disclose supervision
  prominently at point of sale, get written buyer consent to the supervision
  profile, and either retain no remote control after sale or treat retained
  control as an MDM relationship with its own agreement.
- Marketplace note: undisclosed restricted devices invite FTC/state
  deceptive-practices complaints and eBay/Swappa takedowns.

## 6. Ways to sell a pre-supervised iPhone to a consumer

Five workable architectures, ordered by tamper resistance. KolBo validated
the two ends of this spectrum: their original Kosher iPhone business was
Model A; their current KolBo Secure is Model E applied to used or existing
hardware.

### Model A — ABM + ADE + MDM (the original Kosher iPhone model)

1. Register a business entity, get a D-U-N-S number, enroll in
   [Apple Business Manager](https://business.apple.com/).
2. Buy iPhones (new or used, any channel) and add them to your ABM org with
   Apple Configurator — Apple explicitly supports adding devices
   [not purchased from Apple or an authorized reseller](https://support.apple.com/guide/apple-business-manager/axm200a54d59/web).
3. Assign devices to an MDM (Jamf Now, Mosyle, SimpleMDM, Kandji, Hexnode;
   or self-hosted NanoMDM/MicroMDM — per-device cost is roughly $1–4/mo).
4. Ship the phone pre-enrolled. Automated Device Enrollment re-applies
   supervision and MDM at every activation — **a factory reset or DFU
   restore re-enrolls the device automatically**.
5. Push restrictions as MDM payloads: app whitelist, Safari/App Store
   removal, web content filter, *prevent profile removal*, *prevent Erase
   All Content and Settings*.

Caveats: Configurator-added devices give the user a
[30-day provisional window](https://support.apple.com/guide/apple-business-manager/axm200a54d59/web)
to release themselves from ABM/supervision/MDM (devices purchased through
an authorized reseller channel that assigns directly to your ABM have no
such window). You carry ongoing MDM infrastructure, a subscription
relationship, and disclosure/consent obligations. Strongest product,
heaviest ops.

### Model B — Tethered Configurator supervision, no ABM/MDM

Supervise each phone with Configurator, apply non-removable restriction
profiles and preinstalled apps, sell it, walk away. No ongoing
relationship, no infrastructure, no subscription.

- Escape hatch: a full erase/restore removes supervision entirely.
- Cleanest ownership story (no lingering control after sale), grayest
  Configurator-SLA reading (see §1).
- Right shape for an MVP to validate demand before building Model A.
- Back up the **supervision identity** (Keychain export). If it is lost,
  locked profiles cannot be modified — only a restore can.

**Model B-2 — password-gated removal (chosen direction).** Same as B, but
the profile is installed *removable with a `RemovalPassword`* instead of
non-removable: the user can remove it in Settings → VPN & Device Management
by entering the password. `RemovalPassword` is a
[supervised-only key](https://developer.apple.com/business/documentation/Configuration-Profile-Reference.pdf),
so Configurator supervision is still step one (needed anyway — the NE
content filter and the useful restrictions are supervised-only).

- Best consent story of all models: user can exit anytime, seller keeps
  zero remote control; the password is pure friction — the GetBored thesis.
- **Per-device random passwords** keyed to serial, stored server-side. A
  shared static password leaks once and unlocks every device sold.
- Password custody defines the product tier: (a) GetBored holds it, app
  offers "request removal" with a cooldown delay; (b) sealed envelope in
  the box (offline, no dependency on us); (c) accountability partner.
- Passwords cannot be rotated remotely — set at install; changing requires
  a tethered session or remove-and-reinstall with the old password.
- Leave `allowEraseContentAndSettings` **enabled**: Settings-erase and DFU
  restore bypass the password anyway, and an always-available nuclear exit
  is the honest fallback if the password service ever disappears.
- Profile contents: web content filter payload (locks FilterDataProvider
  config), disallow app removal (GetBored can't be deleted), disallow
  account/VPN modification.

### Model C — Configurator supervision + MDM enrollment (no ABM)

Configurator can auto-enroll a device into an MDM during prep without ABM.
On a supervised device the enrollment profile can be locked (user cannot
remove it), and MDM can block user-initiated erase — but a DFU restore
still escapes, because without ADE nothing re-enrolls at activation.
Middle ground: remote management and updates without ABM, weaker than A.

### Model D — Customer-performed supervision (the Tech Lockdown model)

Sell the phone *unsupervised* plus a kit/guided session in which the
customer supervises their own device (their Mac, or a remote session where
they act). No Configurator-SLA exposure for you at all — the "organization"
is the customer. Weakest lock-in (they hold the supervision identity), but
zero license risk and zero infrastructure. Works as a service attach to a
software product rather than a hardware business.

### Model E — Sell hardware and supervision as separate transactions (KolBo Secure model)

Sell the used iPhone as plain hardware; at checkout the customer enrolls it
in your supervision service (self-service portal → your ABM via
Configurator for iPhone or profile enrollment → your MDM, subscription
billed monthly). Commerce and management are cleanly separated: the
customer owns the phone outright and *subscribes* to being locked down.
This is KolBo's current validated model at $14.99/month — and it also works
for phones you didn't sell (pure BYOD), which is how the business scales
beyond your own inventory.

### Model F — Lease, don't sell: phone-as-a-service with retained ownership (GuardianLock model)

Added 2026-07-03 after finding **[GuardianLock](https://guardianlock.org/)**
("SafePhone as a Service™", secular, families/kids/seniors/self-advocates):
they supply pre-configured supervised iPhones on a monthly subscription and
**retain ownership of the device** — "Your affiliate subscription includes
the use of a phone that GuardianLock retains ownership of," with a 24-month
device replacement cycle, one-time activation fee, month-to-month billing,
and trade-in credit for the customer's old phone. Their published feature
set (untrusted-profiles blocked, passcode resets blocked, VPNs blocked, no
sideloading, app allowlists) is the supervised+MDM payload catalog.

**Why the lease structure matters legally:** ABM's "Authorized Devices"
definition covers devices *owned or leased by the institution*. A retained-
ownership fleet is genuinely company-owned — the same footing as hotel-room
iPads, hospital patient iPads, and kiosk deployments, which are mainstream,
Apple-documented ABM+MDM use cases handed to non-employees every day. The
consumer never owns the phone, so the "supervising a personally-owned
device" bar in §1b never triggers. This is arguably the **only fully
ABM-clean way to put a supervised iPhone in a consumer's pocket**, at the
cost of ops weight (inventory, returns, replacement cycles) and a
harder-to-sell "you don't own it" pitch. GetBored relevance: if Model B-2
validates demand and the business wants reset-surviving enforcement plus a
subscription, Model F may be the cleaner upgrade path than seeking ABM
written consent under Model E/A.

### Comparison

| | A: ABM+ADE+MDM | B: Configurator only | C: Config+MDM | D: Customer self-supervise | E: Separate sale + service |
|---|---|---|---|---|---|
| Survives factory reset | **Yes** | No | No (DFU escapes) | No | Yes if ABM-backed |
| Ongoing infra | MDM + ABM | None | MDM | None | MDM + ABM + portal |
| Recurring revenue | Natural | None | Possible | Service fee | **Natural** |
| License standing | **Contractually barred for consumers** (ABM §1b) — tolerated in practice | Gray (Configurator SLA only) | Gray | **Cleanest** | Contractually barred (ABM §1b) if ABM-backed |
| Ops complexity | High | Low | Medium | Lowest | High |
| User escape hatch | 30-day window, then none | Erase any time | DFU restore | Own the keys | Per service terms + 30-day window |

### Recommendation for GetBored

Supervision's killer feature for us is that supervised devices can make the
Network Extension filter config non-removable — the exact hole in the
consumer (unsupervised) story. Path of least regret:

1. **Validate with Model B** — a handful of used iPhones, supervised, with
   GetBored + locked filter config preinstalled, sold with prominent
   disclosure and written consent. No infra, tests willingness to pay.
2. **Graduating to Model E/A means accepting the ABM problem** (§1b): the
   ABM agreement bars supervised enrollment of consumer devices without
   Apple's written consent, so the upgrade path is either (a) use the
   agreement's request mechanism to ask Apple for consent ("You may
   request, and Apple may approve, in its sole discretion, other similar
   users"), or (b) operate as a tolerated breach the way The Kosher iPhone
   did — knowing the whole fleet hangs on an ABM account Apple can
   terminate. This retroactively validates choosing B-2 first: it is not
   just the simplest model, it is the only one that touches no Apple
   account or agreement Apple can revoke.

## 7. Companies that supervise iPhones specifically for content filtering

Verified 2026-07-03. The dominant pattern: **the customer (or parent)
performs or authorizes supervision on hardware the family already owns.**

> **⚠ Correction (2026-07-03, later the same day):** the earlier version of
> this section claimed "nobody ships pre-supervised iPhone hardware." Two
> verified counterexamples were then found — **kPhone** (pre-configured
> iPhones sold through schools since ~2019) and **BSD Phones** (used
> "Filtered, Waze Only" iPhones sold over the counter and online in
> Lakewood). See their entries below. The corrected claim: nobody ships
> pre-supervised iPhones **direct-to-consumer as a general-purpose
> self-control device** — the two existing sellers are institution-gated
> (kPhone) or single-purpose navigation devices (BSD). GetBored's Model B-2
> slot (consumer-direct, full-featured, friction-based) is still empty.

- **[kPhone](https://www.kphone.org/)** (kphone.org, kPhone Inc., domain
  registered 2019-08-11 — a ~7-year operation) — **sells iPhones with its
  kosher management system pre-installed**, iPhone-only ("we do not work
  with Android"). Distribution is **schools-only**: "kPhone can not be
  purchased by individuals, we only work with schools" (named yeshivos:
  Portnoys, Senters, Nesivos Ahron — which restrict students to black
  iPhone 7/8/SE). $9/month or $99/year + $25 activation; phones ship
  unlocked, any carrier. Alternative flows: walk-in appointment or "Ship
  Us a Phone" to install on a student's existing iPhone. Architecture
  tells: a "custom kosher app store" of school-approved apps (= MDM app
  distribution), ongoing remote management/monitoring with usage reports
  to the school, per-school app-approval workflow, different
  vacation/alumni policies pushed remotely — i.e., **supervision +
  retained MDM (Model C), sold through institutions**, operating openly
  since 2019 with no visible Apple enforcement.
- **[DumbSmartphones](https://dumbsmartphones.com/)** (secular — "The
  Modern Flip Phone Built on iPhone") — pre-configured distraction-free
  iPhones on subscription: $10/month Standard (blocks major social and
  entertainment apps) or $20/month Custom (personalized app/site blocking +
  time-based access rules); "ship us your existing phone or have a new one
  sent to us"; explicitly states it uses "Apple's secure MDM tools" and
  that restrictions are "locked at the system level — you can't cheat it or
  delete it" (the non-removability claim implies supervision). Cancel or
  pause anytime. The closest secular analog to GetBored's Model B-2 value
  proposition, structured as Model E (hardware pass-through + management
  subscription). *(Unverified adjacent lead: thekosherphone.org, reportedly
  an iPhones-only preloaded-software seller, blocks automated access —
  claim from a search-result snippet, not confirmed first-hand.)*
- **[GuardianLock](https://guardianlock.org/)** (secular — families, kids,
  seniors, disabled self-advocates) — "SafePhone as a Service™": supplies
  **pre-configured supervised iPhones on subscription while retaining
  ownership** (see Model F, §6). Refurbished ("ES") to premium ("EX")
  models, app allowlists per user goal, DNS filtering, untrusted profiles /
  passcode resets / VPNs / sideloading all blocked. BYOD ("YES" service)
  explicitly still in testing — at launch, supplied hardware only. Proof
  that the pre-configured-iPhone-in-a-box offer exists in the secular
  digital-wellness market too, structured as a lease to stay ABM-clean.
- **[BSD Phones](https://bsdphones.com/)** (Blue Saving Deals Inc, 104
  Clifton Ave, Lakewood NJ) — **sells pre-configured used iPhones
  outright, direct to consumers, today**: an
  [iPhone SE 2nd gen "Filtered Waze Only"](https://bsdphones.com/products/iphone-se-second-gen-unlocked-all-carriers)
  at $200 and an iPhone 12 mini at $237, both 64 GB, unlocked, "filtered
  for navigation purposes only," preinstalled with Waze / Google Maps /
  Weather / CarPlay, and "for added assurance **the browser is fully
  removed** as well." No talk/text, no subscription mentioned — a
  one-time hardware sale. An app-allowlisted iPhone with Safari removed
  implies Configurator supervision (app allowlisting is a
  supervised-only payload). This is **Model B as a live retail product**
  — the "Waze-only device" genre the KolBo guide described — proving a
  store can sell supervised-locked used iPhones over the counter without
  Apple intervening. The gap between this and GetBored's B-2 is scope
  (single-purpose navigation vs. general-purpose friction phone), not
  architecture.

- **[Tech Lockdown](https://www.techlockdown.com/protect-iphone-settings)**
  (secular, self-control/anti-porn — closest comparable to GetBored).
  Membership includes an "Apple Config Generator" that produces custom
  supervised configuration profiles: web content filter payload with
  Apple's built-in adult filter, [locked DNS](https://www.techlockdown.com/articles/enforce-vpn-iphone),
  VPN enforcement, [supervised app blocking](https://help.techlockdown.com/hc/en-us/articles/33612762904596-Supervised-App-Blocking-for-iPhones),
  and a self-binding "[lock the editor](https://www.techlockdown.com/articles/enforce-content-filter-iphone)"
  feature (you can add restrictions but not reduce them). Customers
  supervise their own device following their
  [guides](https://www.techlockdown.com/articles/enable-supervised-mode-iphone)
  (Configurator or iMazing). Pure Model D at commercial scale.
- **[OurPact](https://www.ourpact.com/apple-parental-controls)** (mainstream
  parental control, Apple-blessed post-guideline-5.5). Full app-blocking
  requires the parent to USB-connect the child's iPhone to the OurPact
  Connect desktop app, which **supervises the device** — consumer tethered
  supervision at mainstream scale, performed by the device-owning family.
- **[Covenant Eyes](https://www.techlockdown.com/articles/covenant-eyes-iphone-review)**
  (Christian accountability market). Doesn't supervise itself, but the
  ecosystem's standard fix for iPhone removal-bypass is Supervised Mode +
  supervised app blocklists layered around it.
- **[Canopy](https://support.canopy.us/portal/en/kb/articles/ios-removal-prevention-setup-guide-choose-your-os)** —
  softer approach: no supervision required; "Removal Prevention" = admin
  password + accountability notification when the app is removed.
  (Friction-by-notification rather than OS enforcement.)
- **[Netspark](https://www.netsparkmobile.com/en/kosher-internet-filter/) /
  Rimon / TAG / Israel Connection** (kosher, Israel + US). Netspark for iOS
  is installed via a guided flow or **in person at TAG / Israel Connection
  offices**, where staff supervise customer iPhones with Configurator to
  lock the filter — supervision-as-an-in-person-service.
- **[GenTech](https://www.gentechsolution.com/wiki/apple-restrictions/)**
  (kosher) — supervision-based Apple restrictions + AI content filtering
  service for customer devices. **Install mechanics (verified 2026-07-03):**
  customers bring the iPhone in (or use GenTech's PC installer), the device
  is **wiped and supervised**, and the filter is locked on. Their own
  [iOS install wiki](https://www.gentechsolution.com/wiki/filter-installation-ios/)
  confirms the supervision tell-tales: requires a PC with iTunes and a USB
  tether, requires **turning OFF Find My iPhone** first (the prerequisite
  for a Configurator restore), and "the filter cannot be uninstalled by the
  user and can only be uninstalled with the assistance of a technician."
  This is the closest working analog to GetBored's Model B/B-2 supervision
  flow — operating openly for years, at community scale, with no Apple
  enforcement.

**The Livigent ecosystem — the kosher-filter market's actual structure
(added 2026-07-03):** most kosher iPhone filters are one technology sold
through many community brands. **[Livigent](https://www.livigent.com/)**
(built by RnD Software group) is a B2B AI content-filter engine that
licenses **only in bulk to businesses/organizations** with no end-user
support; community-facing resellers buy licenses and add the install,
support, and hechsher layers. Livigent claims ~150,000 mobile devices in
~20 countries via resellers including **GenTech**, **Meshimer** (Letaher
hechsher; iOS installed in person by their technicians), **[Geder](https://www.geder.org/)**,
Jnet, Netzach, and VCF. The same two-layer structure repeats elsewhere:
Netspark's engine behind TAG/Rimon installs, and KolBo licensing its suite
to Android device manufacturers.

Other companies in the same market, different enforcement models:

- **[filttr](https://www.filttr.org/)** — kosher filter for
  iPhone/Android/Windows/Mac. Notable for being **honest about its iOS
  mechanics where KolBo is vague**: a managed configuration profile
  installed "from a personal link in under two minutes," passcode-locked
  profile, Safari allowlist, App Store hidden, forced encrypted DNS,
  VPN/Private Relay blocked. Self-service, no wipe, no supervision — i.e.,
  exactly the unsupervised-profile architecture we infer KolBo Secure uses,
  but disclosed. Per-person portal for allowlist requests; "home / bochur /
  office" preset levels; optional accountability partner.
- **[Techloq](https://www.techloq.com/help/faq)** — Windows/Android only
  (no iOS product). Its anti-tamper model is **social, not technical**:
  customers can bind their account to a "restricted reseller" (typically a
  TAG office), after which high-risk changes and *uninstall requests route
  to the reseller for approval* instead of Techloq — accountability-gated
  removal, the same design space as GetBored's password-custody question
  for Model B-2.
- **[NetFree](https://techkosher.org/netfree/)** (Israel) — network-level
  kosher internet: filtering enforced at the ISP/network layer with
  per-customer screening profiles (whitelist/blacklist/keyword), supported
  at TAG offices in the US. No device modification needed — the Israeli
  centralized pattern (§3, Meushar) applied to data service.
- **[MB Smart](https://mb-smart.net/)** — third filter brand named on
  TAG's approved-filter roster alongside GenTech and Netspark.
- **KolBo Secure** — BYOD iPhone protection; enrollment mechanics
  undisclosed publicly, most plausibly unsupervised profile-based MDM (see
  §3). Deep-crawl of their pages (2026-07-03,
  [walkthrough](https://kolbo.life/learn/protect-any-iphone-or-android/) and
  [tamper-resistance](https://kolbo.life/learn/tamper-resistant-protection/))
  yields only four claims, all quoted from their own homepage with no
  mechanics: (1) enforcement "at the device-policy level," (2) fail-closed
  design ("remove the management layer and the safeguard stays locked"),
  (3) "AI sight protection" screening images/video/text in real time,
  (4) tiers "from encrypted DNS to full-path content inspection." Their own
  pages admit the gaps: "enrollment mechanics beyond the portal
  description... and platform-specific behaviors aren't stated," and on
  factory reset: "Reset behavior isn't detailed on the homepage, so this
  library doesn't claim specifics."

  **Technical tension worth noting:** on iOS the claims can't all hold
  simultaneously. "Device-policy level" third-party enforcement on iOS
  means MDM/configuration profiles. A "minutes, no technicians,
  self-service" BYOD enrollment produces an *unsupervised* enrollment —
  which Apple guarantees the user can remove in Settings (and User
  Enrollment is removable by design). True fail-closed non-removability
  requires supervision, which for a BYOD iPhone means a wipe via
  Configurator/iMazing — not "minutes." Their careful refusal to answer
  the factory-reset FAQ (reset-survival is exactly what ABM enrollment
  would provide) suggests the iOS implementation fails open on erase,
  i.e., it is *tamper-resistant marketing* over an unsupervised-profile
  reality. The Android side can genuinely deliver fail-closed via Device
  Owner mode.

  **Portal discrepancy:** kolbo.life states "the portal the homepage
  points to is kolbofilter.com" — but kolbofilter.com (fetched
  2026-07-03) is a static KolBo Technologies brochure site (© 2025) with
  no login, no enrollment flow, and no billing; it advertises "KolBo
  Filter" at a different price ($12.99/month vs Secure's $14.99), and
  still promotes the Kosher Phone (thekosherphone.com, "hardware,
  software, device management, and filtering in one complete package")
  and footer-links "The Kosher iPhone." The advertised self-service
  portal does not visibly exist — consistent with §3's finding that this
  is a fast-moving 2026 brand experiment, not a mature operation.

Tooling note: [iMazing](https://imazing.com/supervision) offers
consumer-accessible supervision on **Windows and macOS** — relevant for
GetBored ops and for customer-performed supervision flows (Model D)
without requiring the customer to own a Mac.

## 8. Business-model deep-dives: the three pre-configured-iPhone sellers

Researched 2026-07-03 (catalog enumeration + site crawl + WHOIS).

### BSD Phones — kosher retail: hardware margin + attach revenue

**Who:** Blue Saving Deals Inc, 104 Clifton Ave, Lakewood NJ. Retail
storefront + Shopify site, 150 SKUs.

**Revenue stack (from their own catalog):**

1. **Hardware margin** on kosher/basic phones ($124–400: CAT S22 kosher
   $290, Kyocera $200–245, Qin F30 variants, Fig, TCL, Wonder, Sonim) and
   the used filtered iPhones ($200–237).
2. **Filter-configuration fee** — "Kosher Filter Option" / "FILTER
   OPTIONS" sold as a **$25 one-time add-on** at checkout. The lockdown
   itself is a productized service line.
3. **Recurring service plans under their own brand** — "BSD UNLIMITED
   TALK+TEXT+DATA" from $15/month, data plans $21/$29/$41/month, SIM +
   activation $15+$5. They resell carrier service (MVNO-style), converting
   one-time phone buyers into monthly subscribers.
4. **Attach**: accessories (median catalog price $34), six "Annual
   Warranty" SKUs, kosher home phones, hotspots, Waze GPS devices
   (AutoWays).
5. **Channel breadth**: WHOLESALE and RENTAL categories, plus a KIDS line
   — they supply other stores and rent devices (short-term/travel use).

**Read:** the filtered iPhone is not a business line; it's one SKU in a
"whatever the community needs, filtered" assortment. The model's engine is
local trust + attach economics. Notably, the $25 filter fee proves
customers will pay separately for the act of locking a device down.
Per-device config at retail scale, no MDM, no ongoing management — the
iPhones are almost certainly fire-and-forget Configurator jobs (Model B).

### DumbSmartphones — micro-SaaS on Apple MDM, pre-product-market-fit

**Who:** anonymous (WHOIS-proxied), domain registered **2025-10-10** —
about 9 months old. No founders named, no company entity disclosed.

**Model:** pure management-subscription (Model E without the hardware
margin): $10/month Standard (blocks major social/entertainment apps,
keeps Messages/Maps/Camera/Notes, monthly updates) or $20/month Custom
(personalized app/site blocking, time-based rules, priority one-on-one
setup, "focus reviews"). Customer ships in an existing iPhone or "has a
new one sent" — DumbSmartphones holds no inventory and takes no hardware
risk. Enforcement: "Apple's secure MDM tools," "locked at the system
level — you can't cheat it or delete it." Cancel or pause anytime;
unlock-on-cancel terms undisclosed.

**Read:** this is the minimum-viable version of the GetBored hardware
thesis — no inventory, no store, just supervision-as-a-subscription at
impulse pricing. Its existence (and youth) says the secular demand is
believed in but not yet proven; its anonymity and thin site say switching
costs of trust haven't been solved. The mail-your-phone-in flow is the
main UX tax (days without a phone) — exactly the friction an in-person or
preloaded-hardware offer (B-2) removes.

### GuardianLock — full-stack phone-as-a-service at telco ARPU

**Who:** GuardianLock™ (guardianlock.org, registered 2024-06-01;
co-founder Caden Johnson; "30+ years combined experience" team).
Positioning: "the World's first SafePhone as a Service™" for families,
kids, seniors, and disabled self-advocates. **Entity/jurisdiction:**
operated under holding company **Legacy Portfolio, LLC** (per their
privacy policy and terms); governing law "the United States and the
State of California/Arizona" (their terms' odd dual-state phrasing).
Likely Arizona-based — an LLC of near-identical name ("Legacy Portfolio
Holdings LLC," Gilbert AZ, formed 2023-07-13) predates the domain by a
year, though the exact-name match is unconfirmed.

**The ABM-engineered contract (key finding):** GuardianLock's terms are
drafted in the ABM agreement's own vocabulary: "The mobile hardware
provided (the 'Authorized Device') is a **corporate asset owned by
GuardianLock and its holding company, Legacy Portfolio, LLC**. This
relationship constitutes a **bailment** solely for the delivery of our
managed educational environment. You are considered a **'Permitted
User' of a corporate asset as defined by Apple Business terms**."
Someone there read the same ABM constraints as §1b and engineered the
consumer relationship to fit them: retained ownership → devices are
genuinely "Authorized Devices"; the customer is a bailee, not an owner;
and the service is framed as a "Managed Educational and Safety
Platform." This is independent, in-the-wild confirmation of the doc's
§1b→Model F reasoning — the lease/bailment wrapper is how a real company
lawyered supervised consumer iPhones into ABM compliance.

**Model (from their Shopify subscription catalog):** three leased-device
tiers, all bundling **device + wireless service + management + a "digital
safety education program"**:

- **ES (Essential Safety)**: $65–90/month — assigned *certified
  refurbished* iPhone, preconfigured, "Protected Wireless Access."
- **ADV (Advanced)**: $100–145/month — assigned managed iPhone, GL
  Safety+ training, fuller customization.
- **EX (Executive)**: $165–235/month — latest-model phones, "Complete
  Customizable Profiles and Flexible Family Management."
- Promo: "New Line Offer" — new iPhone 17e bundled at $75/month first
  year, $0 activation, new-number customers only.

Structure: one-time activation fee, month-to-month with rate fixed for a
24-month term, device replaced every 24 months, **GuardianLock retains
device ownership** (§6 Model F), trade-in credit accepted, Verizon
preferred with other carriers expanding. Distribution: an **affiliate/MLM
layer** — every customer is auto-enrolled as an affiliate and "will be
paid for every referral." BYOD ("YES") explicitly not launched.

**Scale check (2026-07-03):** no public revenue, funding, or customer
numbers exist — no Crunchbase profile, no press, no reviews, tiny social
handles (guardianlock822), site built by a small marketing agency.
Given $65–235/month ARPU, even ~1,000 subscribers ($0.8–2.8M ARR) would
leave more public footprint than this; the observable traction is
consistent with tens-to-low-hundreds of subscribers (~$50–500k ARR,
inference not data). Treat GuardianLock as a validated *offer design*,
not a validated *business*.

**Read:** GuardianLock prices like a carrier, not an app — $65–235/month
against DumbSmartphones' $10. The bundle (lease + airtime + curriculum +
referral commissions) is doing three jobs at once: it keeps the fleet
company-owned (ABM-clean supervision, §6 Model F), it buries the
management fee inside a familiar "phone bill" mental model, and it funds
customer acquisition through the affiliate layer instead of ads. The cost
is enormous ops surface (inventory, carrier contracts, 24-month refresh,
returns) and an MLM optic that a self-control brand may not want.

### What the three models say for GetBored's B-2

- **Pricing brackets discovered:** $25 one-time (BSD's filter fee) →
  $10–20/month (DumbSmartphones) → $65–235/month all-in (GuardianLock).
  A B-2 used-iPhone sale with a one-time configuration fee sits in a
  proven bracket; a management subscription above ~$20/month needs
  bundled value (service plan, education, hardware refresh) to justify.
- **Nobody combines** BSD's walk-out-with-it immediacy, DumbSmartphones'
  self-control positioning, and honest friction-based removability. B-2
  still has no direct competitor.
- **The ops ladder is real:** BSD does config-at-sale with zero ongoing
  infrastructure; DumbSmartphones runs an MDM but no inventory;
  GuardianLock runs inventory + MDM + carrier + curriculum. Each rung
  buys enforcement durability with ops weight — matching the doc's
  B → E → F escalation path.

## Sources

- [Apple Configurator SLA (PDF)](https://www.apple.com/legal/sla/docs/AppleConfigurator.pdf)
- [Supervise devices with Apple Configurator — Apple Support](https://support.apple.com/guide/apple-configurator-mac/supervise-devices-apd9e4f64088/mac)
- [Add devices using Apple Configurator to Apple Business Manager — Apple Support](https://support.apple.com/guide/apple-business-manager/axm200a54d59/web)
- [What to do before you sell or give away your iPhone — Apple Support](https://support.apple.com/en-us/109511)
- [App Store Review Guidelines update, June 2019 — Apple Developer](https://developer.apple.com/news/?id=06032019j)
- [MacRumors: Apple lets parental apps use MDM with strict privacy](https://www.macrumors.com/2019/06/04/apple-lets-parental-apps-use-mdm-strict-privacy/)
- [9to5Mac: Apple walks back MDM parental control apps ban](https://9to5mac.com/2019/06/04/parental-control-mdm-apple/)
- [AppleInsider: Apple eases up on parental control app restrictions](https://appleinsider.com/articles/19/06/04/apple-eases-up-on-third-party-parental-control-app-restrictions-introduces-new-mdm-guidelines)
- [The Kosher iPhone](https://thekosheriphone.com/) / [KolBo Secure](https://kolbo.life/learn/protect-any-iphone-or-android/)
- [KolBo: The 2026 kosher phone guide](https://kolbo.life/learn/kosher-phones-2026/) — defines device certification and maps the certifier landscape
- Kosher device certification bodies: [TAG](https://tag.org/en) · [TAG Baltimore: Not So Kosher Phones](https://tagbaltimore.org/not-so-kosher-phones/) · [Trust phone (L'maaseh hechsher)](https://trustkosher.com/) · [Kosher Signal FAQ](https://koshersignal.com/pages/faqs)
- Israel's centralized system: [Jerusalem Post — bill codifying the Rabbinical Committee's kosher-phone control](https://www.jpost.com/israel-news/article-810934) · [Times of Israel — kosher-phone reform backlash](https://www.timesofisrael.com/kosher-phone-freedom-policy-changes-hard-to-swallow-for-ultra-orthodox-rabbis/amp/) · [Tzarich Iyun — What's Kosher About Kosher Phones?](https://iyun.org.il/en/sedersheni/what-is-kosher-about-kosher-phones/)
- [GenTech iOS](https://www.gentechsolution.com/sign-up-ios/) · [TAG Atlanta filters](https://tagatlanta.org/filters/)
- [Balance Phone](https://www.thebalancephone.com/) · [Techless Wisephone review](https://thephoenixspirit.com/2024/07/techless-wisephone-review/)
- [Tech Lockdown: dumb iPhone guide](https://www.techlockdown.com/articles/dumb-phone-iphone)
- Pre-configured iPhone sellers (§7/§8): [kPhone](https://www.kphone.org/) · [BSD Phones](https://bsdphones.com/) ([FAQ](https://bsdphones.com/pages/faq), [iPhone SE listing](https://bsdphones.com/products/iphone-se-second-gen-unlocked-all-carriers)) · [DumbSmartphones](https://dumbsmartphones.com/) · [GuardianLock](https://guardianlock.org/) ([subscription shop](https://shop.guardianlock.org/collections/subscription-options))
- Filter ecosystem (§7): [Livigent](https://www.livigent.com/internet-services-providers/) · [GenTech iOS install](https://www.gentechsolution.com/wiki/filter-installation-ios/) · [filttr](https://www.filttr.org/) · [Techloq FAQ](https://www.techloq.com/help/faq) · [NetFree via Tech Kosher](https://techkosher.org/netfree/) · [Geder](https://www.geder.org/) · [MB Smart](https://mb-smart.net/) · [Meshimer iOS](https://www.meshimer.com/MobileiOS)
