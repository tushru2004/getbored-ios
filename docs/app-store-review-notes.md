# App Store Review Package — GetBored iOS v1

Source of truth for the reviewer-facing text. Paste the relevant sections into
App Store Connect at submission time. Refs: tushru2004/GetBored#149.

---

## 1. App Review Notes (App Store Review — "App Review Information → Notes")

GetBored is a **consumer self-control / digital-wellbeing app**. The person who
owns the device voluntarily chooses which websites and apps distract them, and
GetBored blocks those on that same device. It is not parental control, not
device monitoring, and it does not manage anyone else's device.

**Important — why the content filter may show "Setup required" on your test device:**

The blocking is enforced by an on-device Network Content Filter
(`NEFilterDataProvider`, `content-filter-provider` entitlement). On iOS, a
Network Content Filter configuration can only be *activated* on a **supervised
device**, via a Web Content Filter configuration profile. This is an Apple
platform requirement — the app itself cannot switch the filter on with its own
API on a standard, unsupervised device.

Because of this, on a stock (unsupervised) review device the app correctly
stops at a **"Protection missing"** setup screen. **This is expected behavior,
not a bug.** What the app itself shows on an unsupervised device:

- A welcome screen with **Sign in with Apple** (any Apple ID; Hide My Email
  supported).
- An **Activation** screen where a one-time activation code unlocks the
  account. Codes are issued to customers during onboarding, when their device
  is set up for the filter — so on a stock review device the flow correctly
  stops here. (Activated customers whose profile is absent additionally see a
  **"Protection missing"** gate that fetches their managed filter profile and
  hands it to Settings — shown in the demo video context.)

Block lists themselves are created in the companion GetBored web dashboard (not
in the iOS app) and sync down to the device automatically.

**Demo video:** We have attached a demo video (also viewable at
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v2.mp4) showing the filter
**active on a supervised device**, blocking a user-chosen website in Safari, so
you can verify the core blocking behavior end to end.

**If you would prefer hands-on testing:** we are happy to ship you a
pre-supervised device, or provide step-by-step Apple Configurator instructions
to supervise a spare device. Just let us know.

**Entitlement justification:** `content-filter-provider` is used solely to run
the device owner's **own** content filter locally. The filter inspects network
flows on-device only to decide allow/block against the user's own rules.

**Data handling:**
- **Inspected:** network connection metadata is evaluated locally, on-device, by
  the filter extension to enforce the user's own block rules. It is not uploaded.
- **Stored / synced:** the user's account (Sign in with Apple identity — a
  private relay address when Hide My Email is used), their own filter lists
  (list names, chosen blocked domains/apps), and a device-registration
  identifier, kept on GetBored's own servers and scoped to that account.
- **Diagnostics:** first-party only — on certain errors the app uploads its own
  recent log entries and crash reports to GetBored's servers to support the
  beta. These never include browsing history or filtered-traffic contents.
- **Not collected:** no browsing history upload, no third-party analytics, no
  advertising identifiers, no tracking. No data is sold or shared.

Thank you — happy to answer any questions or supervise a device for you.

---

## 2. Beta App Review Information (TestFlight external — "What to Test")

Paste this whole section into the external group's **What to Test** box at
submit time (TestFlight review notes are text-only — no file attachment field).

⚠️ PLEASE READ FIRST — THE CORE FILTER CANNOT BE ACTIVATED ON A STANDARD DEVICE

GetBored blocks distracting websites and apps with an on-device Network
Content Filter (NEFilterDataProvider). On iOS that filter can only be turned
ON on a *supervised* device, via a managed Web Content Filter profile — an
Apple platform requirement the app cannot bypass. The website/app blocking
itself therefore cannot be exercised on a stock, unsupervised review device.
This is expected behavior, not a bug.

ON A STANDARD (UNSUPERVISED) REVIEW DEVICE you'll see:
1. A welcome screen with a single "Sign in with Apple" button (any Apple ID
   works; Hide My Email is fine).
2. An Activation screen asking for a one-time code. Codes are issued to
   customers during onboarding, when their device is set up for the filter.
   Since the filter could not be enabled on an unsupervised device anyway,
   this screen is where the flow correctly stops on a stock review device.

TO SEE THE FULL FLOW (filter ACTIVE on a supervised device, same build),
please watch this demo video:
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v2.mp4
It shows the activated dashboard — filter status, "Turn Filtering On", and the
read-only "Active rules" list that syncs from the GetBored web dashboard — and
then Safari blocking a website the user chose.

If hands-on verification is needed, we are happy to arrange a supervised
review device or provide supervision steps — just contact us.

SIGN-IN
No demo account needed — Sign in with Apple with any Apple ID. Activation
codes are issued during customer onboarding (see above).

CONTACT
Tushar — tushru2004@gmail.com

---

## 3. Positioning guardrails (App Store description + metadata)

Lead with (per #149):
- Self-control · digital wellbeing · focus boundaries
- "Block the distractions you choose" · voluntary commitment · "your device, your rules"

Avoid as primary framing:
- Parental control · spy / surveillance · hidden monitoring · "cannot be removed"
- "Lock down someone else's phone" · MDM as the consumer-facing concept

Any supervised-device / managed wording stays **secondary** and only where
technically accurate (i.e., explaining the one-time setup that activates the
filter).

---

## 4. Demo video shot list (record later)

Target 45–90s, screen-recorded on the supervised device.

1. **Open GetBored** → show the home/status screen (Content Filter row).
2. **Create a rule** → add a distracting website (e.g. a social site) to a block
   list. Narrate: "I'm choosing to block this site for myself."
3. **Show filter is Active** → status reads "Active & Protecting" (supervised
   device, profile installed).
4. **Open Safari → visit the blocked site** → show it is blocked.
5. **Visit a non-blocked site** → loads normally (proves it's targeted, not a
   blanket block).
6. (Optional) **Remove the rule** → revisit the site → now loads. Shows the user
   is in control.

Narration keeps the self-control framing throughout: "my device, my rules, I
turn this on for myself."
