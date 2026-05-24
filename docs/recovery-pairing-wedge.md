# Recovery: iPhone Pairing Wedge

The iPhone intermittently appears as "unpaired" in Xcode after a build/install cycle, blocking `make install`. The recovery procedure below is empirically validated; the precise mechanism is not pinned down.

## Symptoms

- Xcode run destination dropdown: "iPhone is not available because it is unpaired"
- Window -> Devices and Simulators: "A connection to this device could not be established. Internal logic error: Connection was invalidated"
- `xcrun devicectl list devices` shows `pairingState=paired` but `tunnelState=unavailable`, `transportType=nil`
- `make install` fails with `CoreDeviceError 1011 / DeviceIdentifier ecid_... not located`

## Current Understanding

An earlier hypothesis that `GetBoredSharedCore.xcframework` was linked but not embedded was refuted:

- `GetBoredSharedCore.xcframework` is a static Kotlin/Native archive. Its symbols are linked into each consumer binary.
- There is no `@rpath/...SharedCore` `LC_LOAD_DYLIB` entry in the built bundles.
- `GetBored.app/Frameworks/` should contain `hermes.framework`; SharedCore should not be embedded as a dynamic framework.

Current working theories include stale `lockdownd` state on the device, an iOS/CoreDevice RemotePairing issue after sleep or disconnect cycles, or stale Mac-side mobile device state.

## Diagnostics

```bash
xcrun devicectl list devices --verbose | grep -A 30 'iPhone XR'
ls iOSDeviceDerivedData/Build/Products/Debug-iphoneos/GetBored.app/Frameworks/
otool -L iOSDeviceDerivedData/Build/Products/Debug-iphoneos/GetBored.app/PlugIns/iOSFlowInspector.appex/iOSFlowInspector
nm iOSDeviceDerivedData/Build/Products/Debug-iphoneos/GetBored.app/PlugIns/iOSFlowInspector.appex/iOSFlowInspector.debug.dylib | grep KotlinBase | head
find ~/Library/Logs/DiagnosticReports/ -name "*FlowInspector*" -mtime -7
system_profiler SPUSBDataType | grep -B 1 -A 6 -iE 'iPhone|Apple Mobile'
```

What to check:

- `devicectl` shows `tunnelState=unavailable`: wedge confirmed.
- `Frameworks/` contains `hermes.framework`.
- `otool -L` on the appex does not show `@rpath/GetBoredSharedCore...`.
- `nm | grep KotlinBase` returns Kotlin Native runtime symbols.
- `system_profiler` still sees the phone over USB, meaning USB enumeration is fine.

## Recovery

1. Disable the filter on the phone, either in the GetBored app or by removing the GetBored filter profile in Settings.
2. Unplug USB, wait 3 seconds, replug, unlock the phone, and tap Trust if prompted.
3. Run `xcrun devicectl list devices`; XR should be available with `tunnelState=connected`.
4. Re-run `make install`.
5. Re-enable the filter after install completes.

## Avoid

- Do not reset Location & Privacy unless there is a separate reason.
- Do not use `idevicepair` as the first fix; the pairing record is usually fine.
- Do not restart the Mac for this specific wedge before checking device state.
- Do not chase `rapportd`, HAP, or keychain until USB/CoreDevice state points there.
- Do not embed `GetBoredSharedCore.xcframework`; it is static.

## Prevention

`scripts/preflight-check.sh` runs before `make install` and blocks shipping a build with missing required dynamic frameworks. It intentionally does not check `GetBoredSharedCore` because SharedCore is static.
