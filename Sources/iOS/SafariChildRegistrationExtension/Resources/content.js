function hostnameFromURL(rawValue) {
  try {
    return new URL(rawValue, document.baseURI).hostname.toLowerCase();
  } catch {
    return null;
  }
}

function collectChildDomains() {
  const parentDomain = location.hostname.toLowerCase();
  const childDomains = new Set();

  for (const entry of performance.getEntriesByType("resource")) {
    const host = hostnameFromURL(entry.name);
    if (host && host !== parentDomain) childDomains.add(host);
  }

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

function sendProbe() {
  const message = {
    ...collectChildDomains(),
    probeStage: "content-script"
  };

  browser.runtime.sendMessage(message).then(
    (response) => console.log("GetBored child-registration probe sent", response),
    (error) => {
      console.warn("GetBored background probe failed; trying native direct", error);
      sendNativeProbeDirect({
        ...message,
        probeStage: "content-script-direct-native",
        backgroundError: String(error?.message ?? error)
      });
    }
  );
}

function sendClearProbe(reason) {
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

async function sendNativeProbeDirect(message) {
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

sendProbe();

let pending = false;
const observer = new MutationObserver(() => {
  if (pending) return;
  pending = true;
  setTimeout(() => {
    pending = false;
    sendProbe();
  }, 1500);
});

observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ["src", "href"]
});

