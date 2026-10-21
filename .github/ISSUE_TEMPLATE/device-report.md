---
name: Device report
about: Report how the patch behaves on your PocketBook (working or not)
title: "[Device report] <model>, FW <version>"
labels: device-report
---

**Device:** <!-- e.g. InkPad Color 3 (PB743K3) -->
**Firmware:** <!-- Settings → About device, e.g. U743k3.6.10.2854 -->
**KOReader version:** <!-- e.g. 2026.07.1 -->
**Patch version:** <!-- from crash.log: "PB Wi-Fi patch X.Y.Z active" -->
**Other patches/plugins touching Wi-Fi:** <!-- e.g. none, Lomig's footer icon, BookOrbit -->

### Checks
- [ ] Turning Wi-Fi on in KOReader connects (how long?)
- [ ] After Wi-Fi off in KOReader, the PocketBook home screen shows Wi-Fi off
- [ ] No "The application needs an Internet connection" prompt on the next connect
- [ ] Progress sync push with "Action when done with Wi-Fi: Turn off" → Wi-Fi off a few seconds later
- [ ] Closing the cover after KOReader turned Wi-Fi on → Wi-Fi off after wake
- [ ] Battery overnight compared with before (optional)

### What happened
<!-- Anything unexpected: freezes, popups, Wi-Fi not turning on/off. -->

### crash.log
<!-- From applications/koreader/crash.log: the lines starting with "PB Wi-Fi" and
     "netagent called with parameters" around what you did. -->
```
```
