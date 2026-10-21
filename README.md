# KOReader PocketBook Wi-Fi fix

A KOReader userpatch for PocketBook e-readers. With it, **turning Wi-Fi off in KOReader actually powers the radio down**. It also stops KOReader leaving the radio on (and draining the battery) after a sync or when the device goes to sleep.

It addresses [koreader/koreader#12705](https://github.com/koreader/koreader/issues/12705) and the PocketBook side of [#14537](https://github.com/koreader/koreader/issues/14537).

> **Status: beta (0.6.1).** It was developed against real crash.logs from one device, an InkPad Color 3 on FW 6.10. See [what's verified](#whats-verified). Reports from other models are very welcome: [open a device report](../../issues/new?template=device-report.md).

## The problem

On PocketBook, stock KOReader:
- **Doesn't power the radio down on "Wi-Fi off".** It only drops the connection (`NetDisconnect()`). The radio and the network service keep running, which drains the battery, often overnight.
- **Can't see that state.** KOReader treats "connected" as "Wi-Fi on", so a powered radio that isn't connected shows as *off* in KOReader, and nothing ever turns it off.
- **Probably postpones the firmware's own Wi-Fi idle-off.** A keep-alive (`NetMgrPing()`) runs every 30 s, and the SDK documents that call as "update wifi poweroff timeout".
- **Leaves Wi-Fi on after syncs.** Progress sync never applies "Action when done with Wi-Fi", and nothing powers Wi-Fi down when the device sleeps.

## What the patch does

All changes are PocketBook-only:

1. **"Wi-Fi off" powers the radio down:** `NetDisconnect()` → `WiFiPower(0)` → `netagent wifi off`. The netagent steps run in the background, so the UI doesn't wait on them.
2. **Connecting works exactly as stock** (`NetConnect()`): a known network in ~1.5 s, or the system network picker. **If connecting fails** (nothing in range, picker cancelled), the radio goes off immediately instead of after a 45 s timeout.
3. **Wi-Fi state is reported correctly:** *on* means the radio is powered, *connected* means associated. KOReader's own "connect or turn off?" prompt and the reader footer's Wi-Fi item then work.
4. **"Disable Wi-Fi connection when inactive" (Network menu) becomes available.** It turns Wi-Fi off after ~5 min without traffic, which is useful after OPDS downloads.
5. **After a manual progress-sync push or pull** that had to turn Wi-Fi on, the patch applies your *Action when done with Wi-Fi* setting about 6 s later.
6. **Sleep, cover close, leaving KOReader, or exit:** if KOReader turned Wi-Fi on, the radio is powered down right away (in ~60 ms, before the firmware freezes KOReader). Wi-Fi you turned on in the PocketBook settings is left alone.

## Install

1. Download [`patches/2-pocketbook-wifi.lua`](patches/2-pocketbook-wifi.lua). Use the *raw* file, not the GitHub web page.
2. Copy it to `applications/koreader/patches/` on the device. Create the folder if needed.
3. **Remove other Wi-Fi patches that override the same functions.** In particular, remove Lomig's `2-pocketbook-wifi-off.lua` and `2-pocketbook-wifi-silent-connect.lua`, and any older copy of this file.
4. Restart KOReader. `applications/koreader/crash.log` should contain `PB Wi-Fi patch 0.6.1 active`.

To uninstall, delete the file and restart. You can also disable it under *Tools → Patch management*.

## Recommended settings (Network menu)

| Setting | Suggested | Why |
|---|---|---|
| Action when Wi-Fi is off | Turn on | Syncs connect without asking first. |
| Action when done with Wi-Fi | Turn off | The radio goes off right after a sync push. |
| Disable Wi-Fi connection when inactive | On | Catches OPDS sessions and anything else that leaves Wi-Fi idle. |
| PocketBook: Wi-Fi off when leaving KOReader | Both on (default) | Power down on sleep, background and exit. |

## What's verified

Verified on an **InkPad Color 3 (U743k3.6.10.2854)** with KOReader 2026.07.1, from crash.logs:

| Behaviour | Status |
|---|---|
| Stock "off" leaves the radio on (the bug) | ✅ reproduced |
| `NetDisconnect` + `WiFiPower(0)` powers the radio down (`eth0` disappears) | ✅ |
| Stock `NetConnect()` connects silently to a known network in ~1.5 s | ✅ |
| `netagent net off` disables networking system-wide, causing the "needs an Internet connection" prompt (so the patch no longer uses it) | ✅ |
| No UI freeze on Wi-Fi off | ✅ |
| Off → on again: no prompt, connects in ~1.5 s | ✅ |
| Wi-Fi off ~6 s after a manual progress-sync push ("Action when done with Wi-Fi: Turn off") | ✅ |
| Wi-Fi off on exit (only if KOReader turned it on) | ✅ (0.5.0); 0.6.0 makes it faster |
| Wi-Fi off on sleep / cover close | ❌ in 0.5.0 (the firmware froze KOReader before the delayed power-down ran); 🧪 fixed in 0.6.0, needs re-test |
| "Disable Wi-Fi when inactive" on PocketBook | 🧪 simulated only |
| Any other model or firmware | ❓ please report |

Other users have reported the same radio-stays-on bug on the Era, Era Lite, Verse, Verse Pro Color, Era Color and InkPad 4.

## Known limitations

- **Connecting blocks KOReader**, as in stock: ~1.5 s at home, or while the system network picker is open. All attempts to connect without `NetConnect()` failed on the InkPad Color 3; see [docs/analysis.md](docs/analysis.md#approaches-that-failed).
- **Leaving KOReader also counts as "background".** PocketBook sends the same event for sleep and for switching apps (library, browser). If KOReader turned Wi-Fi on, switching apps turns it off. You can disable this in the menu.
- **The firmware freezes KOReader right after the sleep event** (immediately on the InkPad Color 3). The power-down therefore happens synchronously in that event. The one exception is kosync *auto-sync*: when the sleep event itself starts a sync connection, the power-down waits for the sync, so on such devices it only happens on the next wake.
- **A sync push away from known networks** shows the system picker. That push isn't queued; push again later.

## Reporting results

Please [open a device report](../../issues/new?template=device-report.md) with:
- your model and firmware (*Settings → About device*), and your KOReader version;
- what you did and what happened;
- the relevant part of `applications/koreader/crash.log`. Lines starting with `PB Wi-Fi` and `netagent called with parameters` are the useful ones.

## Upstream

[`upstream/pocketbook-wifi.diff`](upstream/pocketbook-wifi.diff) is the core fix (items 1–4 above) as a change to KOReader's `frontend/device/pocketbook/device.lua`: one file, +46/−5. [`upstream/PR_DESCRIPTION.md`](upstream/PR_DESCRIPTION.md) is a draft pull request description. The plan is to open the PR once a few more models have been confirmed.

## Tests

`tests/` has a simulation that runs KOReader's real `frontend/ui/network/manager.lua` and the real stock PocketBook network backend against a mocked PocketBook network stack. The mocked parts are inkview, netagent and sysfs, and their timings and behaviours come from the crash.logs above. It reproduces the stock bug and covers every behaviour listed here.

```sh
pip install lupa
git clone --depth 1 https://github.com/koreader/koreader ../koreader
python3 tests/run.py ../koreader                   # the userpatch
# with upstream/pocketbook-wifi.diff applied to ../koreader:
python3 tests/run.py --upstream ../koreader
```

A simulation only checks the assumptions it encodes. Field reports are what matter.

## Credits

- **[Lomig](https://github.com/Lomig/koreader-pocketbook-wifi):** found the netagent teardown and much of what's documented about the PocketBook network stack. This patch started from his userpatches.
- **Mark31415, liskin, NiLuJe** and others in #12705 and #14537, for the analysis.
- The KOReader project.

## License

[AGPL-3.0](LICENSE), the same as KOReader.
