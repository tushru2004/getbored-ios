# Spike #170 freeze (do not change these names)

## Split
- **Qwen 3.8 Max:** Content Blocker extension + embed in Xcode. May edit App files for reload/getState. **May edit `GetBoredIOS.xcodeproj/project.pbxproj`.** Must NOT edit FlowInspector.swift or IOSDecisionCore.swift.
- **GLM-5.3:** Safari-only NE skip. May edit `Sources/iOS/Shared/IOSDecisionCore.swift` and `Sources/iOS/iOSFlowInspector/FlowInspector.swift` only. **Must NOT edit pbxproj or the Content Blocker folder.**

## Frozen IDs
- Extension bundle id: `com.getbored.filter.safaricontentblocker`
- Extension point: `com.apple.Safari.content-blocker`
- App Group: `group.com.getbored.ios`
- Team: `3A3AVFF22Q`
- UserDefaults suite: App Group
- Key `safariContentBlockerEnabled` (Bool): true only if `getStateOfContentBlocker` says enabled. Missing/false/error = disabled (fail closed).

## Rules JSON (Docker spike, if-top-url only)
1. Block `url-filter: .*`
2. `ignore-previous-rules` for document/top-document/popup only when the request host is docker.com or one of its subdomains
3. `ignore-previous-rules` for image, script, style-sheet, font, media, raw, svg-document, fetch, websocket, ping when `if-top-url` matches Docker. Omit document, top-document, child-document, popup.

Never vend `[]`.

Do not remove whiteList→blockSpecific coercion. No unit tests. No App Proxy restore. No MDM.
