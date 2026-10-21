# Changelog

## v0.6.2

- Log why Wi-Fi was or wasn't powered down on each sleep, including the "When going to background or sleep" setting and whether KOReader turned Wi-Fi on itself. Two field "failures" turned out to be that setting being unticked, which used to skip the power-down silently.
- Power down on sleep from `Device:_beforeSuspend()` instead of wrapping `UIManager.event_handlers.Suspend`. Every suspend path goes through it, and plugins can't replace it.

## v0.6.1

- A failed connect (no known network, picker cancelled) now powers the radio down even when the caller ignores `turnOnWifi()`'s result, for example a plugin's own Wi-Fi toggle.

## v0.6.0

- Power the radio down on sleep and on exit right away, in ~60 ms: `WiFiPower(0)` + `netagent wifi off`. Before, it happened after a delay, and on the InkPad Color 3 the firmware froze KOReader before the delay ran out. Exit no longer takes ~3.6 s.

## v0.5.0

- First public version:
  - "Wi-Fi off" powers the radio down (`NetDisconnect` → `WiFiPower(0)` → `netagent wifi off`; deliberately no `netagent net off`).
  - Connecting uses stock `NetConnect()` and fails fast.
  - The radio and connection states are reported separately.
  - "Disable Wi-Fi when inactive" is available.
  - Wi-Fi turns off after a kosync push.
