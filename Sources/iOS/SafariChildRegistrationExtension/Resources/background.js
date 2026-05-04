const nativeApplicationIds = [
  "com.getbored.filter",
  "com.getbored.filter.safarichildregistration",
  "application.id"
];

async function sendNativeProbe(message) {
  let lastError = null;

  for (const applicationId of nativeApplicationIds) {
    try {
      const response = await browser.runtime.sendNativeMessage(applicationId, message);
      console.log("GetBored native probe stored", { applicationId, response });
      return { ok: true, applicationId, response };
    } catch (error) {
      lastError = error;
      console.warn("GetBored native probe failed", { applicationId, error });
    }
  }

  throw lastError ?? new Error("No native application id accepted the probe");
}

browser.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "getbored.childRegistrationProbe") {
    return Promise.resolve({ ok: false, ignored: true });
  }

  return sendNativeProbe({
    ...message,
    tabId: sender?.tab?.id ?? null,
    frameId: sender?.frameId ?? null
  });
});
