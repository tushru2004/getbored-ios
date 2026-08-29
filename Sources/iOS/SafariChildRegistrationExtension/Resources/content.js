/**
 * GetBored Safari Web Extension — child-domain registration script.
 *
 * Safari parent-child registration spike. This target is not part of the
 * Release 1.0 runtime. It observes a page's external hosts and sends the
 * snapshot to the native handler for spike inspection.
 *
 *
 * Why this script exists
 * ──────────────────────
 * The spike tests whether native filtering could associate a raw connection
 * with the page that requested it. A network provider alone cannot know that
 * `sb.scorecardresearch.com` was loaded BY `cnbc.com`. By telling the
 * host app
 *
 *     "the active page is cnbc.com, and it loads
 *      sb.scorecardresearch.com, ad.doubleclick.net, ..."
 *
 * the spike can record a parent-scoped relationship:
 *
 *     "cnbc.com is the active page and declared these child domains."
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
 *   5. Safari spike providers
 *        Read the shared context while evaluating the experiment.
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
		for (const entry of performance.getEntriesByType('resource')) {
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
		for (const element of document.querySelectorAll('[src], [href]')) {
				const host = hostnameFromURL(
						element.currentSrc || element.src || element.href,
				);
				if (host && host !== parentDomain) childDomains.add(host);
		}

		return {
				type: 'getbored.childRegistrationProbe',
				url: location.href,
				parentDomain,
				childDomains: Array.from(childDomains).sort(),
				capabilities: detectExtensionCapabilities(),
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
		const browserGlobal = typeof browser !== 'undefined' ? browser : null;
		const chromeGlobal = typeof chrome !== 'undefined' ? chrome : null;

		return {
				browserProxy: Boolean(browserGlobal?.proxy),
				chromeProxy: Boolean(chromeGlobal?.proxy),
				browserWebRequest: Boolean(browserGlobal?.webRequest),
				chromeWebRequest: Boolean(chromeGlobal?.webRequest),
				browserDeclarativeNetRequest: Boolean(browserGlobal?.declarativeNetRequest),
				chromeDeclarativeNetRequest: Boolean(chromeGlobal?.declarativeNetRequest),
				nativeMessaging: Boolean(browserGlobal?.runtime?.sendNativeMessage),
		};
}

/**
 * Returns the available extension runtime API. Safari exposes `browser`, while
 * some compatible hosts expose `chrome`; callers use the same messaging shape
 * after this lookup succeeds.
 */
function extensionRuntime() {
		if (typeof browser !== 'undefined' && browser?.runtime)
				return browser.runtime;
		if (typeof chrome !== 'undefined' && chrome?.runtime) return chrome.runtime;
		return null;
}

let lastRegistrationStartedAt = 0;
const MIN_REGISTRATION_INTERVAL_MS = 1000;

/**
 * Sends the current page's parent and child-host snapshot to the native spike.
 *
 * Call flow:
 *
 *   page start, visible refresh, or mutation observer → registerChildDomains()
 *       │
 *       ├── runtime messaging unavailable → direct native fallback
 *       ├── previous send started < 1 s ago → return  ← coalesces bursts
 *       └── collectChildDomains() → runtime.sendMessage(message)
 *               │
 *               ├── background relay resolves → log success
 *               └── throws or rejects → direct native fallback
 *
 * The `probeStage` field tells the native spike inspector whether the
 * background relay or the direct fallback delivered the snapshot.
 */
function registerChildDomains(trigger = 'manual') {
		const runtime = extensionRuntime();
		if (!runtime?.sendMessage) {
				console.warn('GetBored child-registration runtime unavailable', {trigger});
				registerChildDomainsViaNativeFallback({
						...collectChildDomains(),
						probeStage: 'content-script-direct-native',
						probeTrigger: trigger,
						backgroundError: 'runtime.sendMessage unavailable',
				});
				return;
		}

		const now = Date.now();
		if (now - lastRegistrationStartedAt < MIN_REGISTRATION_INTERVAL_MS) return;
		lastRegistrationStartedAt = now;

		const message = {
				...collectChildDomains(),
				probeStage: 'content-script',
				probeTrigger: trigger,
		};

		let sendResult;
		try {
				sendResult = runtime.sendMessage(message);
		} catch (error) {
				console.warn(
						'GetBored background probe threw; trying native direct',
						error,
				);
				registerChildDomainsViaNativeFallback({
						...message,
						probeStage: 'content-script-direct-native',
						backgroundError: String(error?.message ?? error),
				});
				return;
		}

		Promise.resolve(sendResult).then(
				response => console.log('GetBored child-registration probe sent', response),
				error => {
						console.warn(
								'GetBored background probe failed; trying native direct',
								error,
						);
						registerChildDomainsViaNativeFallback({
								...message,
								probeStage: 'content-script-direct-native',
								backgroundError: String(error?.message ?? error),
						});
				},
		);
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
		const runtime = extensionRuntime();
		if (!runtime?.sendNativeMessage) {
				console.warn('GetBored native direct probe unavailable');
				return;
		}

		const nativeApplicationIds = [
				'com.getbored.filter',
				'com.getbored.filter.safarichildregistration',
				'application.id',
		];

		for (const applicationId of nativeApplicationIds) {
				try {
						const response = await runtime.sendNativeMessage(applicationId, message);
						console.log('GetBored native direct probe stored', {
								applicationId,
								response,
						});
						return;
				} catch (error) {
						console.warn('GetBored native direct probe failed', {
								applicationId,
								error,
						});
				}
		}
}

// ─── Initial registration ──────────────────────────────────────────────
//
// Runs immediately, at the very start of page load. The page exists
// at this point but most resources have NOT loaded yet, so this first
// snapshot is small (about 5–10 hosts on cnbc.com). The mutation
// observer below catches the rest as they arrive.
registerChildDomains('initial-load');

// ─── Visible-page freshness refresh ────────────────────────────────────
//
// Safari can restore an already-open tab without re-running document_start.
// Refresh the spike's active parent while that page is visible even when its
// DOM is otherwise quiet.
const VISIBLE_REFRESH_INTERVAL_MS = 3000;
let visibleRefreshTimer = null;

function pageIsVisible() {
		return document.visibilityState !== 'hidden';
}

function refreshActiveContext(trigger) {
		if (!pageIsVisible()) return;
		registerChildDomains(trigger);
}

function startVisibleRefreshLoop() {
		if (visibleRefreshTimer || !pageIsVisible()) return;
		visibleRefreshTimer = setInterval(() => {
				refreshActiveContext('visible-heartbeat');
		}, VISIBLE_REFRESH_INTERVAL_MS);
}

function stopVisibleRefreshLoop() {
		if (!visibleRefreshTimer) return;
		clearInterval(visibleRefreshTimer);
		visibleRefreshTimer = null;
}

document.addEventListener('visibilitychange', () => {
		if (pageIsVisible()) {
				refreshActiveContext('visibilitychange-visible');
				startVisibleRefreshLoop();
		} else {
				stopVisibleRefreshLoop();
		}
});

window.addEventListener('pageshow', () => refreshActiveContext('pageshow'));
window.addEventListener('focus', () => refreshActiveContext('focus'));

startVisibleRefreshLoop();

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
let observerStarted = false;

function startMutationObserver() {
		if (observerStarted) return;
		const root = document.documentElement;
		if (!root) {
				document.addEventListener('DOMContentLoaded', startMutationObserver, {
						once: true,
				});
				return;
		}

		observerStarted = true;
		const observer = new MutationObserver(() => {
				if (pending) return;
				pending = true;
				setTimeout(() => {
						pending = false;
						registerChildDomains('resource-mutation');
				}, 1500);
		});

		observer.observe(root, {
				childList: true,
				subtree: true,
				attributes: true,
				attributeFilter: ['src', 'href'],
		});
}

startMutationObserver();
