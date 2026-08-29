# Recovery: iPhone Pairing Wedge

The iPhone intermittently appears as "unpaired" in Xcode after a build/install cycle, blocking `make install`. The recovery procedure below is empirically validated; the precise mechanism is not pinned down.

## Symptoms

- Xcode run destination dropdown: "iPhone is not available because it is unpaired"
- Window -> Devices and Simulators: "A connection to this device could not be established. Internal logic error: Connection was invalidated"
- `xcrun devicectl list devices` shows `pairingState=paired` but `tunnelState=unavailable`, `transportType=nil`
- `make install` fails with `CoreDeviceError 1011 / DeviceIdentifier ecid_... not located`

## Current Understanding

This is a device-transport problem rather than an application dependency problem.
Current working theories include stale `lockdownd` state on the device, an
iOS/CoreDevice RemotePairing issue after sleep or disconnect cycles, or stale
Mac-side mobile-device state.

## Diagnostics

```bash
xcrun devicectl list devices --verbose | grep -A 30 'iPhone XR'
system_profiler SPUSBDataType | grep -B 1 -A 6 -iE 'iPhone|Apple Mobile'
```

What to check:

- `devicectl` shows `tunnelState=unavailable`: wedge confirmed.
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

## Prevention

`scripts/preflight-check.sh` runs before `make install` and blocks installation
when a required dynamic framework is missing. That check is separate from the
CoreDevice pairing state described here.
