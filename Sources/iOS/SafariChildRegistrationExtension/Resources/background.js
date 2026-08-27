const nativeApplicationIds = [
  'com.getbored.filter',
  'com.getbored.filter.safarichildregistration',
  'application.id',
];

/**
 * Relays one accepted content-script probe to the native extension handler.
 *
 * Call flow:
 *
 *   content.js → browser.runtime.sendMessage(message)
 *       │
 *       ▼
 *   onMessage listener → sendNativeProbe(message + sender metadata)
 *       │
 *       ├── each application id, in order → sendNativeMessage(...)
 *       │       └── first success → return its response
 *       └── all candidates fail → throw the final error to content.js
 */
async function sendNativeProbe(message) {
  let lastError = null;

  for (const applicationId of nativeApplicationIds) {
    try {
      const response = await browser.runtime.sendNativeMessage(
        applicationId,
        message,
      );
      console.log('GetBored native probe stored', {applicationId, response});
      return {ok: true, applicationId, response};
    } catch (error) {
      lastError = error;
      console.warn('GetBored native probe failed', {applicationId, error});
    }
  }

  throw lastError ?? new Error('No native application id accepted the probe');
}

browser.runtime.onMessage.addListener((message, sender) => {
  const messageType = message?.type;
  const isRegistrationProbe = messageType === 'getbored.childRegistrationProbe';
  const isClearProbe = messageType === 'getbored.childRegistrationProbeCleared';
  if (!isRegistrationProbe && !isClearProbe) {
    return Promise.resolve({ok: false, ignored: true});
  }

  const senderMetadata = {
    tabId: sender?.tab?.id ?? null,
    frameId: sender?.frameId ?? null,
  };
  return sendNativeProbe({
    ...message,
    ...senderMetadata,
  });
});
