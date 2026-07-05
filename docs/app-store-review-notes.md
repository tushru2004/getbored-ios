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

Because of this, on a stock (unsupervised) review device the app will display a
clear **"Setup required"** state and the filter status will read *inactive*.
**This is expected behavior, not a bug.** What the app itself shows on an
unsupervised device:

- The Content Filter / iCloud Sync status, including the honest "Setup required"
  disclosure and the full app UI and onboarding.
- Registering this device to your own private iCloud (CloudKit) via "Device Sync".
- Pulling the latest rules from iCloud ("Refresh Settings") and viewing them
  read-only under "View Active Rules".

Block lists themselves are created in the companion GetBored web console (not in
the iOS app) and sync down to the device.

**Demo video:** We have attached a demo video (also viewable at
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v1.mp4) showing the filter
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
- **Stored / synced:** only the user's own filter lists (list names, chosen
  blocked domains/apps) and a device-registration identifier, kept in the user's
  **private** CloudKit database in their own iCloud account.
- **Not collected:** no browsing history upload, no third-party analytics, no
  advertising identifiers, no tracking. No data is sold or shared.

Thank you — happy to answer any questions or supervise a device for you.

---

## 2. Beta App Review Information (TestFlight external — "What to Test")

Paste this whole section into the external group's **What to Test** box at
submit time (TestFlight review notes are text-only — no file attachment field).

**⚠️ Please read first — the core filter cannot be activated on a standard
device.** GetBored enforces blocking with an on-device Network Content Filter
(`NEFilterDataProvider`). On iOS that filter can only be turned *on* on a
**supervised** device, via a Web Content Filter configuration profile — an Apple
platform requirement the app cannot bypass. On a normal, unsupervised review
device the app correctly shows a **"Setup required"** notice and the Content
Filter row reads **OFF**. This is expected behavior, not a bug; the website/app
blocking itself cannot be exercised on a stock device.

To see it work end to end (filter **active on a supervised device**, blocking a
user-chosen website in Safari), please watch the demo video:

https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v1.mp4

We're also glad to ship a pre-supervised device, or send Apple Configurator
steps to supervise a spare device, so you can verify hands-on — just let us know.

**What you'll see in the app:** a home screen with (1) a **Content Filter**
status row reading **OFF** with the "Setup required" explanation above, plus an
**iCloud Sync** row; (2) a **Device Sync** card to register this device to your
own iCloud; and (3) a **Filter Settings** card with **Refresh Settings** (pulls
your rules from iCloud) and **View Active Rules** (a read-only view of the rules
synced to this device). Block lists themselves are created in the companion
GetBored web console and sync down to the app.

**Sign-in:** No demo account needed — GetBored uses your own iCloud account
(CloudKit). Just be signed in to iCloud on the device.

**Contact:** Tushar — tushru2004@gmail.com

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
