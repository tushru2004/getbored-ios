// GetBored YouTube Filter - Content Script
// Injected into YouTube pages at document_end
// Only blocks videos/shorts/live from non-whitelisted channels.
// Homepage, search, channel pages, etc. are always allowed.

(function() {
  "use strict";

  // Very visible injection marker (independent of title/meta)
  try {
    if (!document.getElementById("__getbored_banner")) {
      const b = document.createElement("div");
      b.id = "__getbored_banner";
      b.textContent = "GetBored: content script active";
      b.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#111;color:#0f0;padding:6px 10px;font:12px -apple-system,system-ui;opacity:0.9";
      document.documentElement.appendChild(b);
    }
  } catch (e) {}

  function isVideoPage() {
    const path = window.location.pathname;
    return path.startsWith("/watch") ||
           path.startsWith("/shorts/") ||
           path.startsWith("/live/");
  }

  // Track current video ID to detect stale ytInitialPlayerResponse
  function getVideoId() {
    const params = new URLSearchParams(window.location.search);
    return params.get("v") || null;
  }

  function tryExtractChannelFromWindow() {
    try {
      const pr = window.ytInitialPlayerResponse;
      if (!pr || !pr.videoDetails) return null;
      // Verify this response is for the CURRENT video (not stale from previous SPA page)
      const vid = getVideoId();
      if (vid && pr.videoDetails.videoId && pr.videoDetails.videoId !== vid) return null;
      const cid = pr.videoDetails.channelId;
      if (cid && /^UC[\w-]{22}$/.test(cid)) return cid;
    } catch (e) {}
    return null;
  }

  function tryExtractChannelFromScripts() {
    // Only match the videoDetails block for the CURRENT video
    const vid = getVideoId();
    const scripts = document.querySelectorAll("script");
    for (const script of scripts) {
      const text = script.textContent || "";
      if (!text) continue;

      // Look for a block containing our video ID, then extract channelId / browseId
      if (vid && text.includes('"videoId":"' + vid + '"')) {
        let m = text.match(/"channelId"\s*:\s*"(UC[\w-]{22})"/);
        if (m) return m[1];
        m = text.match(/"browseId"\s*:\s*"(UC[\w-]{22})"/);
        if (m) return m[1];
      }
    }
    return null;
  }

  function tryExtractChannelFromHTML() {
    // Some iOS YouTube pages don't expose ytInitialPlayerResponse or readable <script> text.
    // As a fallback, scan the HTML for our current videoId and extract a nearby channelId/browseId.
    try {
      const vid = getVideoId();
      if (!vid) return null;
      const html = document.documentElement && document.documentElement.innerHTML;
      if (!html) return null;
      const idx = html.indexOf('"videoId":"' + vid + '"');
      if (idx < 0) return null;
      const windowText = html.slice(idx, idx + 8000);
      let m = windowText.match(/"channelId"\s*:\s*"(UC[\w-]{22})"/);
      if (m) return m[1];
      m = windowText.match(/"browseId"\s*:\s*"(UC[\w-]{22})"/);
      if (m) return m[1];
    } catch (e) {}
    return null;
  }

  function tryExtractChannelFromDOM() {
    const metaTag = document.querySelector('meta[itemprop="channelId"]');
    if (metaTag) {
      const c = metaTag.getAttribute("content");
      if (c && /^UC[\w-]{22}$/.test(c)) return c;
    }
    // DON'T use generic a[href^="/channel/UC"] links — they can belong to
    // recommended videos or the previous page in SPA navigation.
    return null;
  }

  function extractChannelID() {
    return (
      tryExtractChannelFromWindow() ||
      tryExtractChannelFromDOM() ||
      tryExtractChannelFromScripts() ||
      tryExtractChannelFromHTML() ||
      (window.__getbored_fetchedChannel || null)
    );
  }

  function kickOffFetchChannelFallback() {
    try {
      if (window.__getbored_fetchInFlight) return;
      const vid = getVideoId();
      if (!vid) return;

      window.__getbored_fetchInFlight = true;
      fetch(location.href, { credentials: "include" })
        .then(r => r.text())
        .then(html => {
          try {
            const idx = html.indexOf('"videoId":"' + vid + '"');
            if (idx < 0) return;
            const windowText = html.slice(idx, idx + 12000);
            let m = windowText.match(/"channelId"\s*:\s*"(UC[\w-]{22})"/);
            if (m) { window.__getbored_fetchedChannel = m[1]; return; }
            m = windowText.match(/"browseId"\s*:\s*"(UC[\w-]{22})"/);
            if (m) { window.__getbored_fetchedChannel = m[1]; return; }
          } catch (e) {}
        })
        .catch(() => {})
        .finally(() => { window.__getbored_fetchInFlight = false; });
    } catch (e) {}
  }

  function showBlockPage(reason) {
    // Replacing the full document is unreliable on modern YouTube (SPA + re-hydration),
    // so we overlay a full-screen blocker.
    try {
      if (document.getElementById("__getbored_blocker")) return;

      const overlay = document.createElement("div");
      overlay.id = "__getbored_blocker";
      overlay.style.cssText = "position:fixed;top:0;left:0;right:0;bottom:0;z-index:2147483647;background:rgba(10,10,20,0.98);display:flex;align-items:center;justify-content:center;padding:20px;pointer-events:auto";

      const card = document.createElement("div");
      card.style.cssText = "max-width:480px;width:100%;background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.12);border-radius:24px;padding:42px 32px;text-align:center;font-family:-apple-system,system-ui;color:#fff";

      const icon = document.createElement("div");
      icon.textContent = "🐼";
      icon.style.cssText = "font-size:64px;margin-bottom:16px";

      const h = document.createElement("div");
      h.textContent = "Channel Not Allowed";
      h.style.cssText = "font-size:24px;font-weight:700;margin-bottom:10px";

      const p = document.createElement("div");
      p.textContent = "This YouTube content is not from a whitelisted channel.";
      p.style.cssText = "color:rgba(255,255,255,0.72);line-height:1.6;margin-bottom:18px;font-size:15px";

      const r = document.createElement("div");
      r.textContent = reason;
      r.style.cssText = "display:inline-block;font-size:13px;color:rgba(255,255,255,0.45);background:rgba(255,255,255,0.06);padding:8px 14px;border-radius:10px;margin-bottom:18px";

      const btn = document.createElement("button");
      btn.id = "__getbored_back";
      btn.textContent = "Go Back";
      btn.style.cssText = "padding:12px 20px;border-radius:14px;background:rgba(255,255,255,0.15);color:#fff;border:1px solid rgba(255,255,255,0.22);font-weight:600;font-size:15px";
      btn.addEventListener("click", () => history.back());

      const footer = document.createElement("div");
      footer.textContent = "Protected by GetBored";
      footer.style.cssText = "margin-top:26px;font-size:12px;color:rgba(255,255,255,0.32)";

      card.appendChild(icon);
      card.appendChild(h);
      card.appendChild(p);
      card.appendChild(r);
      card.appendChild(btn);
      card.appendChild(footer);
      overlay.appendChild(card);

      // Insert early (documentElement exists at document_start), then ensure it ends up in <body>
      (document.documentElement || document.body).appendChild(overlay);
      const ensureInBody = () => {
        try {
          if (document.body && overlay.parentNode !== document.body) document.body.appendChild(overlay);
        } catch (e) {}
      };
      ensureInBody();
      try { document.addEventListener("DOMContentLoaded", ensureInBody, { once: true }); } catch (e) {}
      try { setTimeout(ensureInBody, 1000); } catch (e) {}

      // Stop video/audio if present
      try { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch(e) {} }); } catch (e) {}

      // Update banner for debugging
      try {
        const b = document.getElementById("__getbored_banner");
        if (b) b.textContent = (b.textContent || "") + " | OVERLAY SHOWN";
      } catch (e) {}
    } catch (e) {
      // If overlay fails, do nothing (avoid breaking page)
    }
  }

  const WHITELISTED_CHANNELS = [
    "UCzQUP1qoWDoEbmsQxvdjxgQ" // Joe Rogan
  ];

  let attempts = 0;
  const RETRY_MS = 250;
  const MAX_ATTEMPTS = 40; // ~10s
  function checkPage() {
    window.__getbored_attempts = attempts;
    if (!isVideoPage()) return;

    const channelID = extractChannelID();
    if (channelID) {
      // Debug info on banner
      try {
        const b = document.getElementById("__getbored_banner");
        if (b) b.textContent = "GetBored active | channel=" + channelID + (WHITELISTED_CHANNELS.includes(channelID) ? " | ALLOW" : " | BLOCK");
      } catch (e) {}

      if (!WHITELISTED_CHANNELS.includes(channelID)) {
        showBlockPage("Channel " + channelID + " is not whitelisted");
      } else {
        // If we previously fail-closed (UNKNOWN) but later found the real whitelisted channel,
        // remove the overlay so the user isn't stuck until refresh.
        const old = document.getElementById("__getbored_blocker");
        if (old) old.remove();
      }
      return;
    }

    // Retry while YouTube is still hydrating
    if (attempts === 0) {
      window.__getbored_fetchedChannel = null;
      kickOffFetchChannelFallback();
    }
    attempts++;
    if (attempts < MAX_ATTEMPTS) {
      setTimeout(checkPage, RETRY_MS);
      return;
    }

    // Fail-closed on video pages if we can't determine channel ID reliably.
    try {
      const b = document.getElementById("__getbored_banner");
      if (b) b.textContent = "GetBored active | channel=UNKNOWN | BLOCK";
    } catch (e) {}
    showBlockPage("Could not determine channel ID");
  }

  // Start checks
  checkPage();

  // YouTube SPA navigation watcher
  let lastURL = location.href;
  function onURLChange() {
    lastURL = location.href;
    attempts = 0;
    // Remove previous block overlay on navigation
    const old = document.getElementById("__getbored_blocker");
    if (old) old.remove();
    // Reset banner
    try {
      const b = document.getElementById("__getbored_banner");
      if (b) b.textContent = "GetBored: content script active";
    } catch (e) {}
    // Run a couple of quick checks early, then continue on the normal retry loop
    try { setTimeout(checkPage, 150); } catch (e) {}
    try { setTimeout(checkPage, 600); } catch (e) {}
  }

  const observer = new MutationObserver(() => {
    if (location.href !== lastURL) onURLChange();
  });

  const startObserver = () => {
    if (document.body) {
      observer.observe(document.body, { childList: true, subtree: true });
    } else {
      document.addEventListener("DOMContentLoaded", () => {
        observer.observe(document.body, { childList: true, subtree: true });
      });
    }
  };

  startObserver();

  // Backup URL change detector (MutationObserver can miss some SPA transitions)
  try {
    setInterval(() => {
      if (location.href !== lastURL) onURLChange();
    }, 500);
  } catch (e) {}
})();
