# SafariDriver iOS testing: YouTube channel whitelist (Safari Web Extension)

This note documents how we debug and validate the iOS Safari Web Extension that blocks YouTube videos from non-whitelisted channels.

## High-level goal
- Allow YouTube browsing (home/search/channel pages)
- Block video playback pages (`/watch`, `/shorts`, `/live`) unless the video’s channel is in the whitelist

## Key implementation pieces
### 1) Content script injection (Safari Web Extension)
- `YouTubeFilterExtension/Resources/content.js` is injected on:
  - `*://m.youtube.com/*`
  - `*://www.youtube.com/*`
  - `*://*.youtube.com/*`
- `run_at: document_start`

**Debug marker:** the script renders a top green banner (`#__getbored_banner`) so we can confirm injection independent of title/meta.

### 2) Channel ID extraction (mobile YouTube reality)
On iOS YouTube pages, the simplest DOM methods can be missing/unstable:
- `meta[itemprop=channelId]` is often `null` on `m.youtube.com`
- `window.ytInitialPlayerResponse` can be stale during SPA navigation (contains the previous video)
- Some navigations do not expose readable inline `<script>` text

**Current extraction strategy (best-effort, ordered):**
1. `ytInitialPlayerResponse.videoDetails.channelId`
   - Only trusted when `videoDetails.videoId` matches the current URL `v=` param.
2. DOM meta tag (when present)
3. Inline script scanning for blocks that include the current `"videoId":"<v>"` and then extract `channelId` or `browseId`
4. Fallback HTML scan in `document.documentElement.innerHTML` near the `videoId` block
5. Last-resort fetch fallback: `fetch(location.href).text()` and scan the returned HTML near the `videoId` block

### 3) Blocking UI (overlay, not innerHTML replacement)
Replacing `document.documentElement.innerHTML = ...` is unreliable because YouTube re-hydrates the SPA and overwrites it.

We instead show a full-screen `position:fixed` overlay (`#__getbored_blocker`) appended to the DOM:
- inserted at `document_start` to appear early
- then re-parented into `<body>` when it becomes available

### 4) SPA navigation handling
YouTube is a SPA, so URL changes often occur without full reload.

We detect URL changes via:
- `MutationObserver` on `document.body`
- plus a 500ms interval fallback (some transitions can be missed)

On URL change we:
- remove any old overlay
- reset attempts
- run early checks quickly after navigation

### 5) Fail-closed vs false-blocks
To avoid letting non-whitelisted videos slip through, we fail-closed on video pages when channel ID cannot be determined after a bounded retry window.

However, failing closed can temporarily block whitelisted videos if channel data appears late.

**Mitigation:** if we later resolve the channel to a whitelisted ID, we remove the overlay automatically (no refresh required).

## SafariDriver-based verification (USB iPhone)
SafariDriver is the most reliable way we found to validate injection + behavior on-device.

### Prerequisites
1. iPhone connected via USB
2. iOS: Settings → Safari → Advanced → **Remote Automation ON**
3. Safari extension enabled: Settings → Safari → Extensions → GetBored → Allow

### Start safaridriver
```bash
# Kill any old driver
PID=$(pgrep -f safaridriver | head -1)
[ -n "$PID" ] && kill "$PID" 2>/dev/null
sleep 1

safaridriver -p 4444 &
sleep 3
```

### Create a WebDriver session targeting the device
```bash
RESP=$(curl -s -X POST http://localhost:4444/session \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"alwaysMatch":{"browserName":"safari","platformName":"iOS","safari:deviceUDID":"00008020-0004695621DA002E"}}}')
SID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['value']['sessionId'])")
```

### Navigate + read extension state
The banner and overlay are the two key signals:
- `#__getbored_banner` text: shows channel + ALLOW/BLOCK (or “content script active”)
- `#__getbored_blocker` presence: whether we are blocking

```bash
curl -s -X POST "http://localhost:4444/session/$SID/url" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://m.youtube.com/results?search_query=joe+rogan"}' > /dev/null
sleep 8

# Click a result (SPA nav)
curl -s -X POST "http://localhost:4444/session/$SID/execute/sync" \
  -H 'Content-Type: application/json' \
  -d '{"script":"var as=document.querySelectorAll(\"a[href*=\\\"/watch?v=\\\"]\"); for(var i=0;i<as.length;i++){var a=as[i]; var t=(a.textContent||a.innerText||\"\").toLowerCase(); if(t.includes(\"powerfuljre\")||t.includes(\"joe rogan\")){a.click(); return a.href;}} as[0].click(); return as[0].href;","args":[]}' > /dev/null

sleep 12

# Inspect
curl -s -X POST "http://localhost:4444/session/$SID/execute/sync" \
  -H 'Content-Type: application/json' \
  -d '{"script":"return {url:location.href, banner:(document.getElementById(\"__getbored_banner\")||{}).textContent||null, blocked:!!document.getElementById(\"__getbored_blocker\"), fetched:window.__getbored_fetchedChannel||null};","args":[]}' \
  | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['value'], indent=2))"

curl -s -X DELETE "http://localhost:4444/session/$SID" > /dev/null
```

### Expected results
- JRE video: banner `channel=UCzQUP1qoWDoEbmsQxvdjxgQ | ALLOW`, `blocked: false`
- Non-whitelisted video: banner `channel=UNKNOWN | BLOCK` (or a real channel ID with BLOCK), `blocked: true`

## Where the main logic lives
- `GetBoredAdvanceClaude/YouTubeFilterExtension/Resources/content.js`
- `GetBoredAdvanceClaude/YouTubeFilterExtension/Resources/manifest.json`

## Next improvements
- Replace hardcoded `WHITELISTED_CHANNELS` with App Group storage / native messaging so the whitelist UI controls the extension in real time.
- Reduce reliance on HTML scanning by using a stable data source when possible.
