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
**This is expected behavior, not a bug.** Everything else is fully testable
without supervision:

- Creating and editing your own block lists (websites and apps).
- Syncing those rules across your own devices via your private iCloud (CloudKit).
- The full app UI, onboarding, and the honest "Setup required" disclosure.

**Demo video:** We have attached a demo video showing the filter **active on a
supervised device**, blocking a user-chosen website in Safari, so you can verify
the core blocking behavior end to end.

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

## 2. Beta App Review Information (TestFlight external — "Test Information")

**What to test:** Create a self-control block list (add a website and/or an app),
then review it under Active Rules and confirm it syncs across your own devices
via iCloud.

**Sign-in:** No demo account needed. GetBored uses your own iCloud account
(CloudKit) — just be signed in to iCloud on the test device.

**About the "Setup required" filter state:** The on-device content filter can
only be enabled on a *supervised* device (an iOS platform requirement), so on a
standard device the app honestly shows "Setup required" and the filter reads
inactive. Rule creation and iCloud sync are fully testable without supervision.
A demo video of the filter actively blocking on a supervised device is available
on request.

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
