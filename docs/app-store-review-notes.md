# App Store Review Package — GetBored iOS v1

Source of truth for the reviewer-facing text. Paste the relevant sections into
App Store Connect at submission time. Refs: tushru2004/GetBored#149.

---

## 1. App Review Notes (App Store Review — "App Review Information → Notes")

GetBored is a **consumer self-control / digital-wellbeing app**. The person who
owns the device voluntarily chooses which websites and apps distract them, and
GetBored blocks those on that same device. It is not parental control, not
device monitoring, and it does not manage anyone else's device.

**Supported device:** This app is for iPhone.

**Review access and device assignment:** Use the username and password supplied
in App Store Connect's App Review Information fields, then follow these steps in
this order:

1. Open GetBored Companion on the review iPhone, enter the supplied credentials,
   and tap **Sign in**. Wait for the app to complete the login and show the main
   screen. The iPhone registers itself with the review account automatically
   after sign-in.
2. In a web browser, open **https://dashboard.getbored.online** and sign in with
   the same username and password.
3. Open **Devices** and confirm that the review iPhone is listed. If it has not
   appeared yet, return to the iPhone app briefly and then reload the dashboard.
4. Open **Lists**, click **New list**, select **Block List**, name it
   **Block videos**, and create the list.
5. Under **Step 1 of 3 · Sites**, add `youtube.com` and `vimeo.com`.
6. Continue to **Step 2 of 3 · Apps** without adding an app, then continue to
   **Step 3 of 3 · Devices**.
7. Select the newly registered iPhone and click **Apply**.
8. Return to the iPhone app. The assigned rules synchronize automatically and
   can be inspected under **Active rules**.

The app does not claim that filtering is active on an unsupervised device.

**Why live blocking cannot run on a standard review iPhone:**

The blocking is enforced by an on-device Network Content Filter
(`NEFilterDataProvider`, `content-filter-provider` entitlement). On iOS, a
Network Content Filter configuration can only be *activated* on a **supervised
device**, via a Web Content Filter configuration profile. This is an Apple
platform requirement — the app itself cannot switch the filter on with its own
API on a standard, unsupervised device.

On a stock review iPhone, the supplied review account lets the dashboard,
account management, device registration, synchronized rules, and related UI be
reviewed. The app labels this state **Demo mode** and explains that live
filtering requires a supervised iPhone. It does not silently simulate an
active Network Extension.

Normal customer accounts still follow the production path: create an account
or sign in with a GetBored username and password, activate the account, install
the per-customer GetBored configuration profile, then use the app on the
supervised iPhone.

Block lists themselves are created in the companion GetBored web dashboard (not
in the iOS app) and sync down to the device automatically.

**Demo video:** We have attached a demo video (also viewable at
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v2.mp4) showing the filter
**active on a supervised device**, blocking a user-chosen website in Safari, so
you can verify the core blocking behavior end to end.

If Apple requires additional evidence of the live Network Extension beyond the
video, please contact us so we can coordinate an appropriate supervised-device
test arrangement before resubmission.

**Entitlement justification:** `content-filter-provider` is used solely to run
the device owner's **own** content filter locally. The filter inspects network
flows on-device only to decide allow/block against the user's own rules.

**Data handling:**
- **Inspected:** network connection metadata is evaluated locally, on-device, by
  the filter extension to enforce the user's own block rules. It is not uploaded.
- **Stored / synced:** the user's GetBored account username, their own filter lists
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

ON A STANDARD (UNSUPERVISED) REVIEW IPHONE:
1. Open GetBored Companion, enter the review username and password supplied in
   App Store Connect, and tap "Sign in". Wait for the app to complete the login
   and show the main screen. The iPhone registers itself automatically after
   sign-in.
2. In a browser, open https://dashboard.getbored.online and sign in with the
   same username and password.
3. Open "Devices" and confirm that the review iPhone is listed. If it has not
   appeared yet, return to the iPhone app briefly and reload the dashboard.
4. Open "Lists", click "New list", select "Block List", enter "Block videos"
   as the list name, and create the list.
5. Under "Step 1 of 3 · Sites", add youtube.com and vimeo.com.
6. Continue to "Step 2 of 3 · Apps" without adding an app, then continue to
   "Step 3 of 3 · Devices".
7. Select the newly registered iPhone and click "Apply".
8. Return to the iPhone app. The rules synchronize automatically and appear
   under "Active rules".

The app displays "Demo mode" and states that live filtering requires a
supervised iPhone. It does not report the filter as active.

TO SEE THE FULL FLOW (filter ACTIVE on a supervised device, same build),
please watch this demo video:
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v2.mp4
It shows the activated dashboard — filter status, "Turn Filtering On", and the
read-only "Active rules" list that syncs from the GetBored web dashboard — and
then Safari blocking a website the user chose.

If hands-on verification of the Network Extension itself is needed, please
contact us so we can coordinate a supervised-device test arrangement.

SIGN-IN
Use the review username and password entered in App Store Connect's App Review
Information fields. Do not use a personal Apple Account. The review account
does not require an activation code.

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

1. **Open GetBored** → show the home/status screen.
2. **Open the GetBored web dashboard and create a rule** → add a distracting
   website (e.g. a social site) to a block list. Narrate: "I'm choosing to
   block this site for myself."
3. **Return to the app and show the active filter state** → the hero reads
   "GetBored" and the synchronized rule count appears (supervised device,
   profile installed).
4. **Open Safari → visit the blocked site** → show it is blocked.
5. **Visit a non-blocked site** → loads normally (proves it's targeted, not a
   blanket block).
6. (Optional) **Remove the rule** → revisit the site → now loads. Shows the user
   is in control.

Narration keeps the self-control framing throughout: "my device, my rules, I
turn this on for myself."
