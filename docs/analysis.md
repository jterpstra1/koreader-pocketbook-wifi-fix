# Analysis: Wi-Fi power management in KOReader on PocketBook

Against KOReader master `426e932` (2026-10-20). Tracking issue: [koreader/koreader#12705](https://github.com/koreader/koreader/issues/12705).

## 1. Root causes

| # | Cause | Where | Effect |
|---|---|---|---|
| 1 | `turnOffWifi()` only calls `NetDisconnect()` | `frontend/device/pocketbook/device.lua` | The radio stays powered after "Wi-Fi off". |
| 2 | `isWifiOn()` is `QueryNetwork() & NET_CONNECTED`, i.e. "associated" | same | "Radio on, not connected" reads as *off* everywhere. The generic code already handles that state (the toggle menu asks "connect or turn off?"), but PocketBook never reports it. |
| 3 | The PocketBook `Suspend` handler only calls `powerd:beforeSuspend()` | `PocketBook:setEventHandlers` | The generic "disable Wi-Fi on suspend" path never runs. |
| 4 | There is no `getNetworkInterfaceName()` | same | "Disable Wi-Fi connection when inactive" is hidden. If it is set anyway, KOReader crash-loops (draft PR #15183). |
| 5 | `keepWifiAlive` calls `NetMgrPing()` every 30 s while Wi-Fi is on | same (PR #9208) | The SDK describes `NetMgrPing` as "update wifi poweroff timeout", so KOReader probably keeps postponing the firmware's own idle-off. This is inferred from the SDK, not measured. On the InkPad Color 3 it shows up as `netagent ping` every 30 s, which itself fails (`ping: permission denied`). |
| 6 | A failed `NetConnect()` still runs `complete_callback` | same | The radio stays on through a 45 s connectivity check. |
| 7 | kosync never calls `afterWifiAction()` | `plugins/kosync.koplugin` | "Action when done with Wi-Fi" is ignored after syncs, on every platform. kosync's suspend push even brings Wi-Fi *up* during sleep. |

## 2. Design

### Upstream diff (`upstream/pocketbook-wifi.diff`, causes 1, 2, 4, 6)

- **`turnOffWifi()`:** `NetDisconnect()` → `WiFiPower(0)` → `netagent wifi off`, and it unschedules the keepalive.
  - `netagent wifi off` is a no-op where `WiFiPower(0)` already triggers it (InkPad Color 3, Era Lite). It is needed on some units (Verse Pro Color, per Lomig's repo issue #1).
- **`turnOnWifi()`:** stock `WiFiPower(1)` + `NetConnect()`, but it returns `false` on failure, so the caller aborts and powers the radio down right away.
- **`isWifiOn()`:** reads `IFF_UP` from `/sys/class/net/<iface>/flags`. The interface disappears when the radio is off. `isConnected()` uses `NET_CONNECTED` plus a default route.
- **`getNetworkInterfaceName()`:** the interface that has a `wireless/` directory (`eth0` on the devices seen so far).
- **`hasFastWifiStatusQuery = yes`**, which enables the reader footer's Wi-Fi item.

### Userpatch only (policy choices, or plugin-specific)

- **Background turn-off.** The teardown's netagent steps run in the background, in order, with a marker file between them. `NetDisconnect()` once blocked for 3.7 s.
- **Power-down on `Suspend`.** On PocketBook, `Suspend` means sleep, cover close or app switch. If KOReader brought Wi-Fi up, the patch powers the radio down synchronously in the handler, because the firmware may freeze KOReader right after it. The exception: if the event itself started a connection (kosync auto-sync), the patch waits for it to settle, plus 4 s, and `Resume` cancels that delayed power-down.
- **Power-down on exit**, under the same condition.
- **kosync bracket.** An interactive push or pull that went through `beforeWifiAction` is followed by `afterWifiAction()` after 6 s. kosync's progress timeout is 5 s, and kosync also drains its queue and pulls on `NetworkConnected`.
- **A menu entry** for the two leave-KOReader toggles.

## 3. Field results: InkPad Color 3, U743k3.6.10.2854, KOReader 2026.07.1

netagent echoes every invocation into `crash.log` (`netagent called with parameters < … >`). libinkview prints `Time To Connect [ms]` from inside the KOReader process.

**Stock KOReader**
- `WiFiPower(1)` produces `wifi on`. `NetConnect(NULL)` produces `connect`, which reaches a known network in 1359–1835 ms with no dialog.
- With no known network in range, `connect` opens `net_configurator.app`, the network picker.
- The keepalive shows as `netagent ping` every 30 s for as long as Wi-Fi is on. One session shows 22 minutes of pings.
- **"Off" produces only `disconnect`, so the radio stays powered.** The bug is confirmed on this device.

**Teardown**
- `disconnect` → `wifi off` (triggered by `WiFiPower(0)`) brings the radio down in about 1 s.
- `eth0` disappears, and `QueryNetwork()` returns 3 with no `NET_CONNECTED` bits.

**`netagent net off` disables networking system-wide.** The next `NetConnect()` starts `/ebrmain/bin/dialog`: "The application needs an Internet connection". Choosing "Turn on Wi-Fi" runs `netagent net on`, which restarts wpa_supplicant. The log shows `Failed to connect to non-global ctrl_ifname: eth0` and then `Successfully initialized wpa_supplicant`.

So `net off` (which Lomig's teardown uses) must not be part of KOReader's "off".

**Final design**, from a crash.log with `net off` removed:
- **Off → on:** no prompt, and `NetConnect` took 1516 ms. Turning off ran `disconnect` in the background (3.25 s) with no UI freeze.
- **Manual kosync push:** connected, then `afterWifiAction` ran 6 s later, and the radio was down 5 s after that.
- **Exit:** the radio was powered down. The synchronous `netagent disconnect` took ~3.6 s here, which delays a restart by that much.
- **Sleep (0.5.0): failed.** `Suspend` was logged (`Inhibiting user input`), and then nothing until the wake 81 s later. I first read this as the firmware freezing KOReader before the delayed power-down could run.
- **Sleep (0.6.1): failed again**, even though 0.6.1 powers down synchronously in the wrapped `UIManager.event_handlers.Suspend`. Its log line never appeared, although `_beforeSuspend()` clearly ran: the Suspend broadcast and `Inhibiting user input` are both logged. So either the wrapper wasn't in the call chain, or its condition was silently false.
- **0.6.2** hooks `Device:_beforeSuspend()` and `Device:_afterResume()` directly, and logs its decision on every sleep. Whether the 0.5.0 failure was the freeze or the same wrapper problem is unknown.
- **0.6.0** powers down synchronously in the `Suspend` handler, with `WiFiPower(0)` + `netagent wifi off` and no `disconnect`. This is the same thing PocketBook does when its own picker is cancelled, and connects afterwards worked in the logs. Exit uses the same path, so the 3.6 s exit delay is gone.
- **A failed connect left no teardown in the log (0.5.0).** In the same log, a `NetConnect` failure (flaky hotspot, picker cancelled) was followed by no `turnOffWifi()` at all. The likely cause is a caller that ignores `turnOnWifi()`'s `false`, such as a plugin's own Wi-Fi toggle. The picker's own `wifi off` covered it that time. Since 0.6.1, `turnOnWifi()` powers down by itself on failure.
- **Not yet observed:** 0.6.x on a device, and the inactivity timer.

## 4. Approaches that failed

All of these were tried on the InkPad Color 3. Each one gave way to the next because of a crash.log.

1. **`NetConnectSilent(NULL)` on the UI thread.**
   - It blocked for ~28 s per call with no known network in range (return -11). With retries, KOReader froze for ~2.5 min.
   - It is synchronous, so it must never run on the UI thread.
2. **Background `netagent connect`, falling back to `NetConnect()` after 10 s.**
   - `netagent connect` opens the network picker by itself when nothing is in range.
   - The fallback then opened a second picker.
3. **Background `connect` / `connect_silent`, with "interface not up after 3 s" taken to mean "picker cancelled".**
   - The interface isn't reported up while netagent connects, and a phone hotspot takes several seconds.
   - The heuristic therefore killed every connection attempt.
4. **Background `connect` / `connect_silent`, waiting for the netagent process to exit.**
   - Run from a shell, both exit after ~1 s without connecting.
   - `NetConnect()` evidently does more than run `netagent connect`: libinkview's `hw_net_connect` also inhibits suspend (`BAN SUSPEND`) and waits for the link. That is undocumented.

**Conclusion:** connect with stock `NetConnect()` and accept its blocking (~1.5 s, or the picker). The fixes that matter are on the turn-*off* side.

## 5. Open questions

1. **Other models:** whether the interface is `eth0` and disappears when off, and whether `WiFiPower(0)` alone triggers `wifi off`.
2. **NET_CONNECTED:** it is a mask (`0x0f00`) that includes "ready" bits in the SDK. Field logs show it as 0 when not associated, but this isn't specified.
3. **Keepalive vs. inactivity timeout:** whether the keepalive interferes with "Disable Wi-Fi when inactive". `netagent ping` fails without root on the InkPad, so it should add no traffic.
4. **Freeze timing:** on some models (Era Lite, per Lomig) the firmware freezes the process a few seconds into sleep, possibly before the power-down on `Suspend` runs.
5. **SDK alternatives:** whether `NetMgr(int)`, `SetFlightMode()` or `NetDisconnectAsync()` would be cleaner than shelling out to netagent.

## 6. Related work

- **Lomig/koreader-pocketbook-wifi:** the original userpatches and netagent findings. Tested on Era, Verse and Era Lite.
- **Mark31415's patch in #12705:** the full teardown, plus calling `afterWifiAction()` after every connection, which was rejected in review.
- **PRs:**
  - #8546: `WiFiPower(1)` before `NetConnect`.
  - #9208: the keepalive.
  - #14961 / #14999: `NetMgrPing` missing on old firmware.
  - #15183: draft `getNetworkInterfaceName` for PocketBook.
  - #15244: link/route split.
- **Issues:**
  - #14537: no auto-off after sync.
  - #4747: InkPad 3 Wi-Fi standby.
