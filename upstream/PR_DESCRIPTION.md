# Draft PR: PocketBook: actually power the radio down on Wi-Fi off

> Draft. Open this once the patch has been confirmed on more than one model. Before submitting, rebase onto current master and check KOReader's PR template.

## Summary

Fixes #12705. On PocketBook, "Wi-Fi off" only called `NetDisconnect()`, which drops the association but leaves the radio powered. That drains the battery, often overnight. And because `isWifiOn()` meant "associated", KOReader could neither see nor turn off a powered radio that wasn't connected.

## Changes (`frontend/device/pocketbook/device.lua` only)

- **`turnOffWifi()`:** `NetDisconnect()` → `WiFiPower(0)` → `netagent wifi off`, and the keepalive is unscheduled.
  - `wifi off` is a no-op where `WiFiPower(0)` already triggers it, and is needed on some units.
  - Deliberately **not** `netagent net off`: that disables networking system-wide, and the next `NetConnect()` then shows "The application needs an Internet connection".
- **`turnOnWifi()`:** unchanged connection path (`WiFiPower(1)` + `NetConnect()`), but it returns `false` when `NetConnect()` fails, so `enableWifi()` & co. abort and power the radio down at once instead of after the 45 s connectivity check.
- **`isWifiOn()`:** reports the radio state (`IFF_UP` on the Wi-Fi interface, which disappears when the radio is off). `isConnected()` uses `NET_CONNECTED` plus a default route. The existing "connect or turn off?" prompt now works on PocketBook.
- **`getNetworkInterfaceName()`:** makes "Disable Wi-Fi connection when inactive" available. Overlaps with draft PR #15183.
- **`hasFastWifiStatusQuery = yes`:** `isWifiOn()` is a sysfs read now, so the reader footer's Wi-Fi item becomes available.

## Testing

- **On device: InkPad Color 3 (U743k3.6.10.2854), from crash.logs.**
  - The radio goes down on "off" (`eth0` disappears).
  - Connecting is unchanged: ~1.5 s to a known network.
  - No "needs an Internet connection" prompt afterwards.
- **On device: other models.** TODO, add reports.
- **Simulation:** https://github.com/jterpstra1/koreader-pocketbook-wifi-fix/tree/main/tests runs the real `manager.lua` and this backend against a mocked inkview, netagent and sysfs, with behaviour taken from the crash.logs.

## Not included

These are policy choices or plugin changes, and are available as a userpatch in the repository above:
- Powering Wi-Fi down on suspend.
- Powering Wi-Fi down on exit.
- Making kosync honour `afterWifiAction()`.

## Credits

Builds on Lomig's findings (https://github.com/Lomig/koreader-pocketbook-wifi) and the discussion in #12705 and #14537.
