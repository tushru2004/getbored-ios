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
    childDomains: Array.from(childDomains).sort()
  };
}

function sendProbe() {
  const message = collectChildDomains();
  browser.runtime.sendMessage(message).then(
    (response) => console.log("GetBored child-registration probe sent", response),
    (error) => console.warn("GetBored child-registration probe failed", error)
  );
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
