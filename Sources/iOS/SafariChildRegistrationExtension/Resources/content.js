/**
 * GetBored Safari Web Extension — child-domain registration script.
 *
 * Runs at the very start of every page the user visits. Looks at the
 * page's element tree, collects every external host the page loads
 * resources from (advertising networks, trackers, fonts, image servers),
 * and sends that list to the iOS host app so the network filter can
 * decide what to allow.
 *
 *
 * Why this script exists
 * ──────────────────────
 * The iOS network filter (NEFilterDataProvider) only sees raw network
 * connections. It has no way to know that
 * `sb.scorecardresearch.com` was loaded BY `cnbc.com`. By telling the
 * host app
 *
 *     "the active page is cnbc.com, and it loads
 *      sb.scorecardresearch.com, ad.doubleclick.net, ..."
 *
 * the filter can apply a parent-scoped rule:
 *
 *     "if cnbc.com is the active page, allow its declared children;
 *      otherwise block them."
 *
 *
 * What gets sent, and where
 * ─────────────────────────
 * Primary path (used when everything is healthy):
 *
 *   1. content.js (this file)
 *        Looks at the page and builds a list:
 *        { parent: "cnbc.com", children: [...] }
 *
 *   2. browser.runtime.sendMessage(...)
 *        Sends the list to background.js (the extension's
 *        always-running script that lives outside any page).
 *
 *   3. background.js
 *        Forwards the list to the native iOS handler using
 *        browser.runtime.sendNativeMessage(...).
 *
 *   4. SafariWebExtensionHandler.swift (native, runs in the iOS host app)
 *        Saves the list to shared storage (App Group key:
 *        safari_parent_child_active_context_v1).
 *
 *   5. NEFilterDataProvider
 *        Reads that shared storage on every network connection and
 *        applies parent-scoped allow/block.
 *
 * Fallback path (used when step 2 fails):
 *
 *   iOS Safari shuts down background.js after about 30 seconds of
 *   idle time (Apple bug report FB127681420). When the user comes back
 *   to a tab that has been in the background, our first attempt to
 *   message background.js will fail. content.js then talks directly to
 *   the native handler — see registerChildDomainsViaNativeFallback.
 *
 *
 * Re-registration
 * ───────────────
 * Most page resources don't exist when this script first runs. The
 * page loads more scripts, images, iframes, and link tags over the
 * next few seconds (especially on advertising-heavy single-page apps
 * like cnbc.com — about 5 hosts at the start, growing to about 65 by
 * the 3-second mark). To catch them, we watch the page for any new
 * `src` or `href` attributes and re-register, but at most once every
 * 1500 ms so a 200-element ad burst becomes ONE call.
 */


/**
 * Take a URL string (or relative path) and return its lowercased hostname.
 *
 * Called from
 * ───────────
 *   collectChildDomains, twice on every collection pass:
 *     - once per Performance API entry  (Pass 1)
 *     - once per element with src/href  (Pass 2)
 *   This is a hot path — runs hundreds of times per page.
 *
 * What it does
 * ────────────
 *   1. Builds a URL object using `new URL(value, document.baseURI)`.
 *      The second argument resolves relative paths like "/foo.png"
 *      against the page's address, so DOM attributes work the same
 *      as fully-qualified URLs.
 *
 *   2. If the parser throws (which it does on values like
 *      "javascript:void(0)", "mailto:foo@bar.com", or empty strings),
 *      we catch and return null. The caller MUST check for null.
 *
 *   3. Lowercases the hostname so reaching the same server through
 *      "Ad.DoubleClick.NET" and "ad.doubleclick.net" is recognized as
 *      one host (and dedupes when added to a Set).
 *
 * @param {string} rawValue - absolute URL or relative path.
 * @returns {string | null} lowercased hostname, or null if unparseable.
 *
 * @example
 *   hostnameFromURL("https://Ad.DoubleClick.NET/path?q=1")
 *     // → "ad.doubleclick.net"
 *
 *   // page is at https://cnbc.com/markets, so document.baseURI is
 *   // "https://cnbc.com/"
 *   hostnameFromURL("/static/foo.png")
 *     // → "cnbc.com"     (relative path resolved against baseURI)
 *
 *   hostnameFromURL("javascript:void(0)")
 *     // → null            (URL parser throws → caught → null)
 */
function hostnameFromURL(rawValue) {
  try {
    return new URL(rawValue, document.baseURI).hostname.toLowerCase();
  } catch {
    return null;
  }
}


/**
 * Build a snapshot of every external host the current page touches.
 *
 * Called from
 * ───────────
 *   registerChildDomains. The returned object is spread into the
 *   message envelope and sent to the host app. Runs once at page
 *   start, then again at most once per 1500 ms cooldown when the
 *   page mutates new src/href attributes.
 *
 * What "external" means
 * ─────────────────────
 *   Any hostname different from the page's own hostname.
 *   Example: on cnbc.com, "static-redesign.cnbcfm.com" counts as
 *   external because the hostname differs (even though it belongs to
 *   the same company).
 *
 * Two passes — neither alone is complete
 * ──────────────────────────────────────
 *   Pass 1 — Performance API
 *     The browser keeps a record of every network request it has
 *     already finished for this page (scripts, images, stylesheets,
 *     fetch and XMLHttpRequest calls, fonts, beacons). We read that
 *     record. Misses anything queued but not yet completed.
 *
 *   Pass 2 — Element walk
 *     We walk every element on the page that carries a `src` or
 *     `href` attribute. This catches lazy-load images, anchor tags,
 *     and prefetch hints that the Performance API hasn't reported as
 *     fetched yet.
 *
 * Sorting the result keeps successive snapshots stable, so the host
 * app inspector can compare two writes diff-style without spurious
 * reordering noise.
 *
 * @returns {{
 *   type: "getbored.childRegistrationProbe",
 *   url: string,                 // location.href at snapshot time
 *   parentDomain: string,        // page's own hostname (lowercased)
 *   childDomains: string[],      // sorted, deduped external hosts
 *   capabilities: object         // which extension APIs the runtime
 *                                // exposes — pure telemetry
 * }}
 *
 * @example
 *   // Called on https://cnbc.com/markets after the page settles:
 *   collectChildDomains()
 *     // → {
 *     //     type: "getbored.childRegistrationProbe",
 *     //     url: "https://cnbc.com/markets",
 *     //     parentDomain: "cnbc.com",
 *     //     childDomains: [
 *     //       "ad.doubleclick.net",
 *     //       "bat.bing.com",
 *     //       "sb.scorecardresearch.com",
 *     //       "static-redesign.cnbcfm.com",
 *     //       // ... ~60 more
 *     //     ],
 *     //     capabilities: { nativeMessaging: true, ... }
 *     //   }
 */
function collectChildDomains() {
  const parentDomain = location.hostname.toLowerCase();
  const childDomains = new Set();

  // ── Pass 1 — Performance API ────────────────────────────────────
  // Each `entry.name` is the absolute URL of one completed network
  // request, for example
  //     "https://sb.scorecardresearch.com/beacon?c1=2&c2=..."
  for (const entry of performance.getEntriesByType("resource")) {
    const host = hostnameFromURL(entry.name);
    if (host && host !== parentDomain) childDomains.add(host);
  }

  // ── Pass 2 — Element walk ───────────────────────────────────────
  // `currentSrc` is the actual URL the browser picked from a
  // <picture>/srcset choice. We use that when present, otherwise
  // fall back to plain `src` (img/script/iframe) and `href` (link/a).
  //
  //     <img src="https://static-redesign.cnbcfm.com/foo.png">
  //     <link href="https://fonts.googleapis.com/css2?family=...">
  for (const element of document.querySelectorAll("[src], [href]")) {
    const host = hostnameFromURL(element.currentSrc || element.src || element.href);
    if (host && host !== parentDomain) childDomains.add(host);
  }

  return {
    type: "getbored.childRegistrationProbe",
    url: location.href,
    parentDomain,
    childDomains: Array.from(childDomains).sort(),
    capabilities: detectExtensionCapabilities()
  };
}


/**
 * Detect which network-control extension APIs the current browser exposes.
 *
 * Called from
 * ───────────
 *   collectChildDomains. The result is embedded as the `capabilities`
 *   field of every probe payload. There is no other consumer in this
 *   file.
 *
 * What this is for
 * ────────────────
 *   Pure telemetry. We include this in every payload so the host app
 *   can show the developer, at a glance, which network-control surfaces
 *   would be available if we ever shipped a real network filter as a
 *   Safari Web Extension instead of using NEAppProxy /
 *   NEFilterDataProvider.
 *
 * What each capability is
 * ───────────────────────
 *   browser.proxy / chrome.proxy
 *     A way for an extension to make per-request proxy decisions in
 *     JavaScript. Firefox desktop only — not present on iOS Safari or
 *     Chrome.
 *
 *   webRequest
 *     A way for an extension to block individual network requests
 *     synchronously from a JavaScript callback. Chrome's older
 *     extension format (Manifest V2) supports it. iOS Safari does not.
 *
 *   declarativeNetRequest
 *     A static rule list with regex and domain filters. Chrome's
 *     newer extension format (Manifest V3) and macOS Safari support
 *     it. iOS Safari has the namespace, but the `initiatorDomains`
 *     field — the one we'd need for parent-scoped allowlisting — is
 *     broken (Apple bug report FB13xxxxx).
 *
 *   nativeMessaging
 *     A way for an extension to send arbitrary JavaScript objects
 *     (encoded as JSON) to the host app's native handler. Present on
 *     iOS Safari. This is the path we actually use.
 *
 * @returns {{
 *   browserProxy: boolean,
 *   chromeProxy: boolean,
 *   browserWebRequest: boolean,
 *   chromeWebRequest: boolean,
 *   browserDeclarativeNetRequest: boolean,
 *   chromeDeclarativeNetRequest: boolean,
 *   nativeMessaging: boolean
 * }}
 *
 * @example
 *   // Observed on iPhone XR running iOS 18.1:
 *   detectExtensionCapabilities()
 *     // → {
 *     //     browserProxy: false,
 *     //     chromeProxy: false,
 *     //     browserWebRequest: false,
 *     //     chromeWebRequest: false,
 *     //     browserDeclarativeNetRequest: true,   // present but broken
 *     //     chromeDeclarativeNetRequest: false,
 *     //     nativeMessaging: true                 // ← the only usable path
 *     //   }
 */
function detectExtensionCapabilities() {
  const browserGlobal = typeof browser !== "undefined" ? browser : null;
  const chromeGlobal = typeof chrome !== "undefined" ? chrome : null;

  return {
    browserProxy: Boolean(browserGlobal?.proxy),
    chromeProxy: Boolean(chromeGlobal?.proxy),
    browserWebRequest: Boolean(browserGlobal?.webRequest),
    chromeWebRequest: Boolean(chromeGlobal?.webRequest),
    browserDeclarativeNetRequest: Boolean(browserGlobal?.declarativeNetRequest),
    chromeDeclarativeNetRequest: Boolean(chromeGlobal?.declarativeNetRequest),
    nativeMessaging: Boolean(browserGlobal?.runtime?.sendNativeMessage)
  };
}


/**
 * Send the current page's parent + child host list to the iOS host app.
 *
 * Called from
 * ───────────
 *   1. The bottom of this file, once at page start. The page exists
 *      but most resources have not loaded yet, so the list is small
 *      (about 5–10 hosts on cnbc.com).
 *   2. The MutationObserver callback at the bottom of this file. When
 *      a new src/href lands, the observer arms a 1500 ms timer.
 *      Further changes that arrive while the timer is running are
 *      ignored, so a burst of 200 ad mutations becomes one re-send.
 *
 * Builds a fresh list every call. The host app overwrites the previous
 * registration, so we don't need to track diffs here.
 *
 * Two paths to the host app
 * ─────────────────────────
 *   Primary (uses background.js as a relay):
 *     content.js
 *       → browser.runtime.sendMessage()
 *       → background.js
 *       → browser.runtime.sendNativeMessage()
 *       → SafariWebExtensionHandler.swift
 *
 *   Fallback (used when background.js is dead — see below):
 *     content.js
 *       → browser.runtime.sendNativeMessage()
 *       → SafariWebExtensionHandler.swift
 *
 * Why the fallback exists
 * ───────────────────────
 *   iOS Safari shuts down background.js after about 30 seconds of
 *   idle time (Apple bug report FB127681420). When the user comes
 *   back to a backgrounded tab and we try to re-register, the primary
 *   `sendMessage` rejects. We then call the fallback, which talks to
 *   the native handler directly — see
 *   `registerChildDomainsViaNativeFallback` below.
 *
 * The probeStage field
 * ────────────────────
 *   `probeStage` is a debug breadcrumb stamped into the payload so
 *   the host app inspector can tell which path delivered any given
 *   message:
 *     - "content-script"               → primary path succeeded
 *     - "content-script-direct-native" → fallback path was used
 *
 * @example
 *   // Healthy case — background.js alive, page just loaded:
 *   registerChildDomains()
 *     // → console.log "GetBored child-registration probe sent"
 *     //   App Group write:
 *     //     safari_parent_child_active_context_v1 = {
 *     //       parentDomain: "cnbc.com",
 *     //       childDomains: [65 hosts...],
 *     //       receivedAt: 2026-05-09T16:08:48Z
 *     //     }
 *
 *   // Failure case — background.js killed by iOS,
 *   //                user returns to a backgrounded tab:
 *   registerChildDomains()
 *     // → console.warn "GetBored background probe failed; trying native direct"
 *     // → registerChildDomainsViaNativeFallback runs
 *     //   (tries 3 application identifiers in turn)
 */
function registerChildDomains() {
  const message = {
    ...collectChildDomains(),
    probeStage: "content-script"
  };

  browser.runtime.sendMessage(message).then(
    (response) => console.log("GetBored child-registration probe sent", response),
    (error) => {
      console.warn("GetBored background probe failed; trying native direct", error);
      registerChildDomainsViaNativeFallback({
        ...message,
        probeStage: "content-script-direct-native",
        backgroundError: String(error?.message ?? error)
      });
    }
  );
}


/**
 * Tell the host app the current page is gone — drop its child mapping.
 *
 * Called from
 * ───────────
 *   NOTHING YET. This function is defined for completeness but is not
 *   wired up to any event in this repository. The intended callers
 *   are:
 *     - a `window.addEventListener("pagehide", ...)` listener,
 *     - the navigation hook for single-page apps that change pages
 *       without a real reload (a `history.pushState` wrapper).
 *
 *   Until one of those is added, the host app relies entirely on the
 *   next page's `registerChildDomains` to overwrite stale state.
 *
 * Why we'd want this
 * ──────────────────
 *   Without an explicit clear, the network filter keeps applying the
 *   cnbc.com child whitelist even after the user has navigated to
 *   nytimes.com. A tracker like sb.scorecardresearch.com loaded on
 *   BOTH sites would be granted under the wrong parent — leaks one
 *   site's allowlist to the next.
 *
 * No fallback path here. We go through background.js only. Losing a
 * clear is annoying but not security-critical, because the next page's
 * register call will overwrite the parent → children mapping anyway.
 *
 * @param {string} reason - debug tag identifying the trigger
 *   ("pagehide", "spa-navigation", etc.). Echoed back in the message
 *   for the host app inspector.
 *
 * @example
 *   // Wire up once at script start (would go in this file or
 *   // background.js):
 *   window.addEventListener("pagehide", () => unregisterChildDomains("pagehide"));
 *
 *   // User clicks a link cnbc.com → nytimes.com:
 *   unregisterChildDomains("pagehide")
 *     // → message: {
 *     //     type: "getbored.childRegistrationProbeCleared",
 *     //     url: "https://cnbc.com/markets",
 *     //     parentDomain: "cnbc.com",
 *     //     reason: "pagehide"
 *     //   }
 *     // → App Group: removes "cnbc.com" entry from
 *     //   safari_parent_child_active_context_v1
 */
function unregisterChildDomains(reason) {
  const message = {
    type: "getbored.childRegistrationProbeCleared",
    url: location.href,
    parentDomain: location.hostname.toLowerCase(),
    reason
  };

  browser.runtime.sendMessage(message).catch((error) => {
    console.warn("GetBored active page clear failed", { reason, error });
  });
}


/**
 * Bypass background.js when it's dead — talk to the native handler directly.
 *
 * Called from
 * ───────────
 *   `registerChildDomains` only — specifically the error branch when
 *   `browser.runtime.sendMessage(...).then(...)` rejects. Never on the
 *   primary path.
 *
 *   It receives the same payload the primary path tried to send, plus
 *   `probeStage = "content-script-direct-native"` and a
 *   `backgroundError` string describing why background.js failed (so
 *   the host app inspector can display it).
 *
 * Why this exists
 * ───────────────
 *   iOS Safari shuts down extension background scripts after about
 *   30 seconds of idle time (Apple bug report FB127681420). The first
 *   message we try to send to a shut-down background.js fails — the
 *   browser is supposed to wake the script on demand, but in practice
 *   that wake is unreliable on iOS.
 *
 *   So when the user returns to a tab that has been in the background
 *   for a while, the primary path is dead. We have to deliver the
 *   payload to the native handler ourselves, from the content script.
 *   The content script can do this because the manifest grants the
 *   `nativeMessaging` permission to the whole extension.
 *
 * Why three application identifiers in a loop
 * ───────────────────────────────────────────
 *   `sendNativeMessage(applicationId, msg)` requires `applicationId`
 *   to match the bundle identifier declared in the host app's
 *   NSExtension Info.plist.
 *
 *   During the spike, the actual binding turned out to be
 *   non-deterministic across builds — it depends on signing identity,
 *   App ID prefix, and whether the code uses the literal placeholder
 *   "application.id" from Apple's sample code.
 *
 *   So we try each candidate in turn. The first one that doesn't
 *   throw wins; the rest get logged as soft failures and we continue.
 *
 *   If the runtime doesn't expose `sendNativeMessage` at all (older
 *   iOS Safari builds), we bail fast.
 *
 * @param {object} message - same payload `registerChildDomains` built,
 *   plus `probeStage = "content-script-direct-native"` and a
 *   `backgroundError` string for the host app inspector to display.
 *
 * @example
 *   // background.js is dead, primary path rejected, so content.js
 *   // calls this:
 *   registerChildDomainsViaNativeFallback({
 *     type: "getbored.childRegistrationProbe",
 *     parentDomain: "cnbc.com",
 *     childDomains: [...],
 *     probeStage: "content-script-direct-native",
 *     backgroundError: "Could not establish connection..."
 *   })
 *     // → tries "com.getbored.filter"                          (rejects)
 *     // → tries "com.getbored.filter.safarichildregistration"  (succeeds)
 *     //     console.log "GetBored native direct probe stored"
 *     //     return — does NOT try "application.id"
 */
async function registerChildDomainsViaNativeFallback(message) {
  if (!browser?.runtime?.sendNativeMessage) {
    console.warn("GetBored native direct probe unavailable");
    return;
  }

  const nativeApplicationIds = [
    "com.getbored.filter",
    "com.getbored.filter.safarichildregistration",
    "application.id"
  ];

  for (const applicationId of nativeApplicationIds) {
    try {
      const response = await browser.runtime.sendNativeMessage(applicationId, message);
      console.log("GetBored native direct probe stored", { applicationId, response });
      return;
    } catch (error) {
      console.warn("GetBored native direct probe failed", { applicationId, error });
    }
  }
}


// ─── Initial registration ──────────────────────────────────────────────
//
// Runs immediately, at the very start of page load. The page exists
// at this point but most resources have NOT loaded yet, so this first
// snapshot is small (about 5–10 hosts on cnbc.com). The mutation
// observer below catches the rest as they arrive.
registerChildDomains();


// ─── Page mutation observer — re-register on new resources ─────────────
//
// Why this exists
// ───────────────
//   Single-page apps and advertising networks load most external
//   resources AFTER the page first appears. On cnbc.com the host
//   count grows from about 5 at the start to about 65 by the
//   3-second mark as scripts inject more <script>, <img>, <iframe>,
//   and <link> elements. Without this observer, the iOS filter would
//   only ever see the initial handful of hosts and would block the
//   ads and trackers that load later.
//
// How it works
// ────────────
//   We watch the entire page for any new src or href. When one
//   arrives we arm a 1500 ms timer. Any further changes that land
//   before the timer fires are ignored — a 200-element ad burst
//   becomes ONE register call instead of 200.
//
// Filtering the events
// ────────────────────
//   `attributeFilter: ["src", "href"]` is the tightest filter the
//   MutationObserver supports. Without it, having `attributes: true`
//   would make us fire on every class/style/aria change too. The
//   filter narrows the firing to only resource-bearing attributes.
//
// Example timeline on cnbc.com
// ────────────────────────────
//   t = 0 ms      page start      → registerChildDomains  (5 hosts)
//   t = 200 ms    <script> insert → observer fires, 1500 ms timer arms
//   t = 400 ms    <img>    insert → timer already running, ignored
//   t = 1700 ms                   → registerChildDomains  (47 hosts)
//   t = 2900 ms   <iframe> insert → observer fires, timer arms again
//   t = 4400 ms                   → registerChildDomains  (65 hosts)
let pending = false;
const observer = new MutationObserver(() => {
  if (pending) return;
  pending = true;
  setTimeout(() => {
    pending = false;
    registerChildDomains();
  }, 1500);
});

observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ["src", "href"]
});
