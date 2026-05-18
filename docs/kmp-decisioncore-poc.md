# KMP DecisionCore POC

Goal: move as much policy decision logic as possible toward Kotlin while keeping
Apple-owned extension lifecycle code in Swift.

## Current boundary

```text
Swift NetworkExtension shell
  - NEFilterDataProvider / NEFilterControlProvider lifecycle
  - extracts host, source app, URL, endpoint
  - converts Kotlin result into NEFilter verdict

Kotlin shared-kotlin module
  - pure rule matching
  - policy-mode interpretation
  - exception matching
  - allowed-app matching
  - Data Provider host classification
  - Safari App Proxy direct and parent-child decisions
```

## Explicit non-goals for this POC

- No CloudKit in Kotlin.
- No App Group reads/writes in Kotlin.
- No React Native bridge yet.
- No full port of `getbored-core`.
- No deployment to a device from this worktree.

## Build once Java/Gradle are available

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk
./gradlew :shared-kotlin:allTests
./gradlew :shared-kotlin:assembleGetBoredSharedCoreXCFramework
xcodebuild -project GetBoredIOS.xcodeproj -scheme "GetBored iOS" \
  -configuration Debug -sdk iphonesimulator -derivedDataPath DerivedData build
```

This worktree vendors the Gradle wrapper so a fresh checkout can build the KMP
module without requiring a globally installed Gradle. Java is still required.

## Swift integration seam

`Sources/iOS/Shared/KMPDecisionCoreAdapter.swift` is the adapter boundary. It
falls back to the existing Swift `GetBoredCore.DecisionCore` if the generated
Kotlin framework is not importable, so plain SwiftPM tests remain safe.

When `GetBoredSharedCore.xcframework` is available, this adapter is the only
Swift file that imports the generated Kotlin framework.

## Xcode linking state for `canImport(GetBoredSharedCore)`

Current state:

- `KMPDecisionCoreAdapter.swift` is compiled into all four current consumers:
  - app target `GetBored iOS`, sources phase `21A6FBD05149665FD3543DAC`
  - extension target `iOSBlockHandler`, sources phase `41947A62280D872B880DC0B3`
  - extension target `iOSFlowInspector`, sources phase `7D4D882803D95285B5038473`
  - extension target `SafariAppProxyProvider`, sources phase `25232264DC073CDF0D5AFB43`
- `shared-kotlin/build.gradle.kts` builds a static Kotlin/Native XCFramework
  named `GetBoredSharedCore` for `iosArm64`, `iosSimulatorArm64`, and `iosX64`.
- The generated module exists at
  `shared-kotlin/build/XCFrameworks/debug/GetBoredSharedCore.xcframework` and
  exposes `DecisionCore` through each slice's
  `GetBoredSharedCore.framework/Headers/GetBoredSharedCore.h`.
- The generated debug XCFramework is referenced from
  `GetBoredIOS.xcodeproj/project.pbxproj` and linked as `Do Not Embed` because
  the framework is static.

Linked Frameworks phases:

- app `GetBored iOS`: `E75E238758A0043A8ABC3E68`
- `iOSBlockHandler`: `ADEBBDB5095FC5ECDFA5333A`
- `iOSFlowInspector`: `08FDAD93015789FD38A86771`
- `SafariAppProxyProvider`: `12F74CC6789891117F8179FF`

Fail-fast Xcode phases:

- The same four Kotlin-consuming targets now run
  `Verify GetBoredSharedCore XCFramework` before their Sources phase.
- The phase checks for
  `shared-kotlin/build/XCFrameworks/debug/GetBoredSharedCore.xcframework` and
  its generated Swift import header.
- If either is missing, Xcode fails with a message to run
  `./gradlew :shared-kotlin:assembleGetBoredSharedCoreXCFramework` instead of
  silently compiling the Swift fallback behind `#if canImport`.

Do not add a copy/embed phase for this POC. The generated binaries are static
archives (`isStatic = true` in Gradle), so each app/appex link product needs the
module during compile and link, but there is no dynamic framework to load at
runtime.

Use the debug XCFramework for this POC. The immediate goal is to make
`#if canImport(GetBoredSharedCore)` flip on in the normal Debug build loop. The
release XCFramework also exists, but Xcode file references are not naturally
configuration-specific; wire Release only after deciding whether to add a
checked-in binary location, an xcconfig-driven generated path, or a Gradle/Xcode
sync step that avoids hard-coding `build/XCFrameworks/debug` into release
builds.

Risks:

- `shared-kotlin/build/...` is generated output. Clean builds or fresh clones
  will lose the XCFramework. Xcode now fails fast for the Kotlin-consuming
  targets when that output is missing, but it still does not generate the
  XCFramework automatically.
- Linking the static Kotlin runtime into the app and NetworkExtension
  appex targets duplicates code size, but the targets are separate bundles and
  each compiles `KMPDecisionCoreAdapter.swift`, so each needs its own link.
- The current XCFramework contains `arm64` device plus `arm64` and `x86_64`
  simulator slices. It is enough for the current simulator build.
- Once `canImport` is true, Swift will compile against the Kotlin API surface.
  Keep `KMPDecisionCoreAdapter.swift` as the only direct import site to avoid
  spreading Kotlin/Native generated types through NetworkExtension code.

## Current migration state

Reviewed:

- `Sources/iOS/iOSFlowInspector/FlowInspector.swift`
- `Sources/iOS/iOSBlockHandler/BlockHandler.swift`
- `Sources/iOS/SafariAppProxyProvider/SafariAppProxyProvider.swift`
- `Sources/iOS/Shared/IOSRuleStore.swift`
- `Sources/iOS/Shared/SafariParentChildContextStore.swift`
- `shared-kotlin/src/commonMain/kotlin/com/getbored/sharedcore/DecisionCore.kt`

### Moved or wired through Kotlin

- `FlowInspector.classifyHost(_:)` now hydrates `LoadedFilterRules`, computes
  the Safari parent exception in Swift, and calls
  `KMPDecisionCoreAdapter.classifyHost(...)`.
- `FlowInspector` app allow/probe checks now call
  `KMPDecisionCoreAdapter.shouldAllowApp(...)` and
  `shouldLogBlockedAppProbe(...)`.
- `FlowInspector` system-domain and exception matching call the adapter.
- `IOSRuleStore.isListed(url:)`, `isExcepted(fullURL:)`, and
  `isAppAllowed(_:)` now route through `KMPDecisionCoreAdapter`.
- `SafariAppProxyProvider.shouldRelayFlow(endpoint:)` now calls
  `KMPDecisionCoreAdapter.directSafariProxyDecision(...)` and
  `parentChildDecision(...)`.
- `SafariParentChildPolicy.swift` was deleted. The parent-child state machine
  now has one implementation behind `KMPDecisionCoreAdapter`.
- `SafariAppProxyProvider` now loads policy through `IOSRuleStore`, so Safari
  and FlowInspector use the same App Group policy snapshot.
- Pure host helpers now route through Kotlin: host normalization,
  exact/subdomain matching, wildcard child-pattern matching, and the legacy
  related-domain keyword heuristic.
- Exception matching intentionally preserves the old iOS runtime prefix
  semantics: an exception pattern allows any normalized URL starting with that
  pattern.
- Own-app bypass is still sourced from Swift identifiers: the adapter passes
  `GetBoredIdentifiers.bundlePrefix` into the Kotlin `PolicySnapshot`.

### Still intentionally Swift-owned

- `SafariAppProxyProvider.refreshActiveContextIfDirectHostMatchesActiveParent(_:)`
  still decides when to refresh App Group context in Swift, but its pure host
  matching now routes through Kotlin.
- `IOSRuleStore.isRelatedToAllowedEntry(host:)` remains a Swift storage-facing
  API, but its legacy keyword heuristic now routes through Kotlin.

### Apple API adapter code that should stay Swift

- `FlowInspector.startFilter(...)`, `stopFilter(...)`,
  `handleNewFlow(_:)`, and `handleOutboundData(...)`: NetworkExtension lifecycle,
  flow-type branching, verdict mapping, and byte peeking stay Swift. The policy
  calls inside them now route through Kotlin where practical.
- `FlowInspector.extractSNI(from:)`, `extractHTTPHost(from:)`, and
  `extractHTTPFullURL(from:)`: these are portable parsers in theory, but they sit
  directly on the byte-peek boundary. Leave them Swift for this one-shot migration
  unless test coverage is added around exact packet/header fixtures.
- `BlockHandler.handle(_:)`, `handleNewFlow(_:completionHandler:)`,
  `scheduleActivityUpload()`, and `uploadActivityLogToCloudKit()`: Control Provider,
  activity logging, and CloudKit upload stay Swift.
- `BlockHandler.resolveBlockedHost(from:sourceApp:)`, `normalizeHost(_:)`,
  `isResolvableHost(_:)`, `sourceAppLabel(_:)`, and `isIPAddress(_:)`: mostly
  telemetry labeling, endpoint resolution, and C socket helpers. Not a main
  Kotlin migration target.
- `SafariAppProxyProvider.startProxy(...)`, `stopProxy(...)`,
  `handleNewFlow(_:)`, `TCPRelay`, `describeRemoteEndpoint(for:)`,
  `host(from:)`, `refreshActiveContextIfDirectHostMatchesActiveParent(_:)`,
  and `appendEvent(_:)`: lifecycle, Apple flow/connection APIs, App Group context
  hydration, and observability stay Swift. Their pure policy decisions call Kotlin.
- `IOSRuleStore.load/save` functions and all `IOSActivityLogger` functions:
  storage and logging adapters stay Swift.

### Remaining follow-up before productionizing

1. Decide whether production builds should generate the XCFramework from Xcode
   or whether CI should run
   `./gradlew :shared-kotlin:assembleGetBoredSharedCoreXCFramework` before
   `xcodebuild`.
2. Decide how Release should resolve the generated framework. This POC hard-codes
   the Debug XCFramework path in Xcode.
3. Measure extension memory after linking Kotlin/Native on a real device. The
   simulator build proves compile/link compatibility, not NetworkExtension memory
   safety.
4. Add parity fixtures for Swift-vs-Kotlin behavior before deleting any remaining
   Swift helper paths.
