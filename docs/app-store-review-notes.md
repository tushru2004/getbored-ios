# App Store Review Package — GetBored Companion v1.1

Source of truth for the reviewer-facing text. Paste the relevant sections into
App Store Connect at submission time. Refs: tushru2004/GetBored#149 and #160.

Draft for the whitelist release. This file does not update App Store Connect.
Before pasting, confirm the review credentials still work and check the steps
against the deployed dashboard; UI labels below were checked against local
dashboard and iOS source. Keep credentials only in App Store Connect's dedicated
sign-in fields, not in this file.

---

## 1. App Review Notes (App Store Review — "App Review Information → Notes")

GetBored is a **consumer self-control / digital-wellbeing app**. The person who
owns the device voluntarily chooses which websites and apps distract them, and
GetBored blocks those on that same device. It is not parental control, not
device monitoring, and it does not manage anyone else's device.

**Supported device:** This app is for iPhone.

**New in version 1.1:** Allow List (whitelist) mode lets the device owner choose
which websites may be opened in Safari. Other website navigation is blocked,
apart from required service/system exceptions. Allowed pages can load supporting
resources. The existing Block List mode remains available for blocking selected
distractions instead. Lists are configured in the companion web dashboard, not
created inside the iPhone app.

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

**Review the new Allow List mode:**

1. Complete sign-in and device registration above. In the dashboard, open
   **Lists → New list**, select **Allow List**, and name it **Review focus**.
2. Add `wikipedia.org` under **Sites**. Do not add `youtube.com`, and do not add
   URL/path exceptions for this check.
3. Continue through **Apps** and **Devices**, select the review iPhone, and
   apply the list. Ensure the earlier **Block videos** list is no longer assigned
   to that iPhone so this check uses one list/mode at a time.
4. Return to GetBored Companion and open **Active rules**. The **Your rules**
   screen should list `wikipedia.org` under **Sites** and show the allow-mode
   subtitle, “Allowing only the items below · everything else is blocked”.
5. On an unsupervised review iPhone, stop at rule synchronization: **Demo mode**
   is expected and websites will not be blocked. On a supervised iPhone with
   the managed content filter active, open fresh Safari pages: `wikipedia.org`
   should load and direct navigation to `youtube.com` should be blocked.
6. To compare modes, replace the assigned Allow List with the **Block videos**
   Block List above. Reopen **Active rules** and confirm the block-mode subtitle.
   On the supervised device, `youtube.com` should remain blocked while an
   unlisted website such as `wikipedia.org` should load.

No Safari web extension installation or Safari extension permission is required.

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

Block and allow lists are created in the companion GetBored web dashboard (not
in the iOS app) and sync down to the device automatically.

**Existing block-mode demo video:**
https://d1lm440g1i1fns.cloudfront.net/getbored-demo-v2.mp4 shows the filter
**active on a supervised device**, blocking a user-chosen website in Safari, so
you can see the existing blocking behavior end to end. This is the earlier
block-mode demonstration, not a demonstration of version 1.1's new Allow List.

If Apple requires additional evidence of the live Network Extension beyond the
video, please contact us so we can coordinate an appropriate supervised-device
test arrangement before resubmission.

**Entitlement justification:** `content-filter-provider` is used solely to run
the device owner's **own** content filter locally. The filter inspects network
flows on-device only to decide allow/block against the user's own rules.

**Data handling:**
- **Inspected:** network connection metadata is evaluated locally, on-device, by
  the filter extension to enforce the user's own filter rules. It is not uploaded.
- **Stored / synced:** the user's GetBored account username, their own filter lists
  (list names, chosen allowed/blocked domains/apps), and a device-registration
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

NEW IN 1.1 — ALLOW LIST / WHITELIST:
1. In the dashboard, create an "Allow List" named "Review focus" containing
   wikipedia.org. Do not add youtube.com or URL/path exceptions.
2. Apply it to the review iPhone, removing the previous Block List assignment
   so only one mode/list is under review.
3. Return to the iPhone app and open "Active rules". Confirm wikipedia.org is
   listed and the subtitle starts "Allowing only the items below".
4. On a supervised iPhone with filtering active, open fresh Safari pages:
   wikipedia.org should load; direct navigation to youtube.com should be blocked.
   Allowed pages can load supporting resources. Required system/service
   exceptions remain available. No Safari web extension is required.
5. Switch back to the Block List and confirm the mode/rules synchronize again.
On an unsupervised iPhone, verify rule display only; live blocking is unavailable.

EARLIER BLOCK-MODE DEMONSTRATION (not the new whitelist flow):
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

## 4. Version 1.1 demo video shot list (not yet recorded/verified here)

Target 45–90s, screen-recorded on the supervised device.

1. **Open GetBored** → show the home/status screen.
2. **Open the GetBored web dashboard** → create an **Allow List** containing
   `wikipedia.org` and assign it to the iPhone, without other list assignments.
   Narrate: "I'm choosing the websites I want to use while focusing."
3. **Return to the app and show the active filter state** → the hero reads
   "GetBored" and the synchronized rule count appears (supervised device,
   profile installed).
4. **Open Safari → visit wikipedia.org** → show it loads.
5. **Navigate directly to youtube.com in a fresh page** → show it is blocked.
6. **Switch to a Block List containing youtube.com** → show the updated mode
   under **Active rules**, then show wikipedia.org loading and youtube.com blocked.

Narration keeps the self-control framing throughout: "my device, my rules, I
turn this on for myself."

---

## 5. What's New — paste-ready

New Allow List mode helps you stay focused by choosing which websites you can
open in Safari. Create an Allow List in your GetBored web dashboard and assign
it to your iPhone; your rules sync to GetBored Companion automatically.

Prefer to block only selected distractions? Block List mode remains available.
Live filtering requires a supervised iPhone with the GetBored configuration
profile installed and filtering active.

## 6. Description addition — paste-ready

Choose how you focus: use a Block List to block selected distracting websites,
or an Allow List to limit Safari browsing to the websites you choose. Manage
your lists in the GetBored web dashboard and view your synchronized rules in
GetBored Companion on iPhone. Allowed websites can load supporting resources;
required system services remain available.

Live filtering requires a supervised iPhone and the GetBored configuration
profile. A standard, unsupervised iPhone cannot activate the content filter.

## 7. Submission handoff — internal, do not paste

- Confirm the dedicated review account can sign in to both the app and the
  deployed dashboard, register a new review device, and assign an Allow List.
- Check the existing privacy/data-handling statements in section 1 against the
  release's logging/upload behavior and App Privacy answers; they are inherited
  from v1 and were not re-audited as part of this wording update.
- Record/upload a version 1.1 whitelist demo using section 4 and insert its real
  URL into both review-note sections. Do not describe the old video as whitelist
  evidence or claim a video is attached unless it actually is.
- Paste sections 1, 2, and 5 into the corresponding App Store Connect fields;
  incorporate section 6 into the description. Check field limits in the UI and
  keep supervision requirements and reviewer access instructions if shortening.
- Ensure screenshots match the release UI. Do not imply the list editor lives
  in the iPhone app; it lives in the web dashboard.
- Select the uploaded v1.1 build and verify saved metadata before submission.
  This document edit does not upload a build or submit the app for review.
