--[[
PocketBook Wi-Fi fixes (koreader/koreader#12705).
https://github.com/jterpstra1/koreader-pocketbook-wifi-fix

Consolidates and reworks the userpatches from
https://github.com/Lomig/koreader-pocketbook-wifi into one file.

What this changes, all PocketBook-only:

1. turnOffWifi() really powers the radio down. Stock only calls
   NetDisconnect(), which drops the association but leaves the radio (and
   netagent/wpa_supplicant) running. Full teardown is
   NetDisconnect() -> WiFiPower(0) -> netagent wifi off. (Not `netagent net
   off`: that disables networking system-wide, and the next NetConnect()
   then asks "The application needs an Internet connection".)

2. turnOnWifi() connects like stock (NetConnect(): ~1.5 s to a known network
   on an InkPad Color 3, the system network picker otherwise), but reports a
   failed connect, so the radio goes down right away instead of after the
   45 s connectivity check. turnOffWifi() runs netagent in the background.
   (Earlier versions of this patch tried to connect without NetConnect();
   none of that worked on the InkPad Color 3, see docs/.)

3. isWifiOn() reports the *radio* state (interface present and IFF_UP),
   isConnected() keeps reporting the association. Stock PocketBook conflates
   the two, so "radio on, not connected" (the battery-draining state from the
   issue) was invisible: the menu showed Wi-Fi as off and nothing ever turned
   it off. With the split, the stock "connect or turn off?" prompt, the
   suspend logic and the reader footer all see the real state.

4. getNetworkInterfaceName() is implemented, which unlocks KOReader's own
   "Disable Wi-Fi connection when inactive" (Network menu). That is the
   proper auto-off mechanism; afterWifiAction() is only used by a couple of
   plugins and is not meant for this.

5. hasFastWifiStatusQuery is set (isWifiOn() is now a sysfs read), so the
   reader footer's Wi-Fi item becomes available.

6. If KOReader powered the radio up itself, it powers it down again when
   KOReader goes to the background/sleep and on exit, synchronously (the
   firmware may freeze KOReader right after the sleep event). Both are toggleable
   under Network -> "PocketBook: Wi-Fi off when leaving KOReader".

7. Progress sync (kosync): a manual push/pull that had to turn Wi-Fi on now
   honours Network -> "Action when done with Wi-Fi" (~6 s after the sync).
   Stock kosync never calls afterWifiAction(), so the radio stayed on.

Install: copy to applications/koreader/patches/ on the device and restart.
Remove Lomig's 2-pocketbook-wifi-off.lua / 2-pocketbook-wifi-silent-connect.lua
first: they override the same functions. His footer icon patch is not needed
(use the reader footer's Wi-Fi item), but is harmless alongside this one.
--]]

local PATCH_VERSION = "0.6.1"

local Device = require("device")
if not Device:isPocketBook() or not Device:hasWifiToggle() then return end

local bit = require("bit")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ffiutil = require("ffi/util")
local userpatch = require("userpatch")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local C = ffi.C

-- Older releases (<= 2026.03) lack the ffi/inkview wrapper module.
local has_wrapper, inkview = pcall(require, "ffi/inkview")
if not has_wrapper then
    require("ffi/inkview_h")
    inkview = ffi.load("inkview")
end

local NETAGENT = "/ebrmain/bin/netagent"
local has_netagent = lfs.attributes(NETAGENT, "mode") == "file"

-- Probe for a usable timeout(1): coreutils/new busybox take "timeout 5 cmd",
-- old busybox wants "timeout -t 5 cmd". Empty when there is none.
local function succeeded(ret) return ret == 0 or ret == true end
local TIMEOUT = ""
if succeeded(os.execute("timeout 1 true >/dev/null 2>&1")) then
    TIMEOUT = "timeout 5 "
elseif succeeded(os.execute("timeout -t 1 true >/dev/null 2>&1")) then
    TIMEOUT = "timeout -t 5 "
end

-- Log how long the blocking inkview/netagent calls take, so a freeze report
-- (crash.log) shows exactly which one hangs on a given device.
local has_time, time = pcall(require, "ui/time")
local function timed(label, fn, ...)
    if not has_time or not time.now then return fn(...) end
    local start = time.now()
    local a, b = fn(...)
    logger.info("PB Wi-Fi timing:", label, "took", time.to_ms(time.now() - start), "ms")
    return a, b
end

-- Blocking, bounded by TIMEOUT when available. Only used on exit, where there
-- is no event loop left to wait in.
local function netagentSync(args)
    if not has_netagent then return end
    return timed("netagent " .. args, os.execute, TIMEOUT .. NETAGENT .. " " .. args .. " >/dev/null 2>&1")
end

-- Runs in the background; touches `marker` when done (if given).
local function netagentBackground(args, marker)
    if not has_netagent then return end
    local done = marker and ("; touch " .. marker) or ""
    os.execute("(" .. TIMEOUT .. NETAGENT .. " " .. args .. done .. ") >/dev/null 2>&1 &")
end

local function isAssociated()
    return bit.band(inkview.QueryNetwork(), C.NET_CONNECTED) ~= 0
end

-- The Wi-Fi interface is eth0 on the devices reported so far, and it vanishes
-- when the radio is powered down. Prefer whichever one has a wireless/ dir.
local IFF_UP = 0x1
local IF_CANDIDATES = { "eth0", "wlan0" }
local detected_iface

local function detectInterface()
    for __, name in ipairs(IF_CANDIDATES) do
        if lfs.attributes("/sys/class/net/" .. name .. "/wireless", "mode") == "directory" then
            return name
        end
    end
end

local function interfaceUp(name)
    local f = io.open("/sys/class/net/" .. name .. "/flags", "r")
    if not f then return false end
    local flags = tonumber(f:read("*l") or "")
    f:close()
    return flags ~= nil and bit.band(flags, IFF_UP) ~= 0
end

local function radioUp()
    detected_iface = detectInterface() or detected_iface
    if detected_iface then
        return interfaceUp(detected_iface)
    end
    for __, name in ipairs(IF_CANDIDATES) do
        if interfaceUp(name) then return true end
    end
    return false
end

local NetworkMgr = require("ui/network/manager")

-- Grab the stock pieces before replacing anything.
local keepWifiAlive = userpatch.getUpValue(NetworkMgr.turnOnWifi, "keepWifiAlive")
local stock_turnOnWifi = NetworkMgr.turnOnWifi
local stock_isConnected = NetworkMgr.isConnected

-- Bumped on every on/off request, so a stale poll loop from an earlier
-- turnOnWifi() can tell it has been superseded and stop.
local generation = 0
-- True while the radio is up because *we* brought it up this session.
local we_powered_on = false
-- Marker the background `netagent disconnect` touches when it's done.
local NET_OFF_MARKER = "/tmp/koreader-pb-wifi-disconnect.done"
local NET_OFF_WAIT_STEPS = 20 -- x 0.25 s
local net_off_pending = false

-- Runs `done` once a background `netagent disconnect` has finished (right away
-- if none is running), so nothing races with it.
local function afterNetOff(my_generation, done)
    local steps = 0
    local function check()
        if my_generation ~= generation then return end
        if net_off_pending then
            steps = steps + 1
            if lfs.attributes(NET_OFF_MARKER, "mode") ~= "file" and steps < NET_OFF_WAIT_STEPS then
                UIManager:scheduleIn(0.25, check)
                return
            end
            net_off_pending = false
            os.remove(NET_OFF_MARKER)
            logger.info("PB Wi-Fi: netagent disconnect finished after ~", steps * 0.25, "s")
        end
        done()
    end
    check()
end

-- Set while powering down on sleep/exit: see turnOffWifi().
local fast_teardown = false

-- `fast`: just cut the radio, synchronously (~60 ms): WiFiPower(0) and
-- `netagent wifi off`, without `netagent disconnect` (3.5+ s). That's what
-- PocketBook itself does when its network picker is cancelled, and the next
-- connect works fine. Used on sleep and exit, where the firmware freezes or
-- ends KOReader right after, so nothing can be left for later.
function NetworkMgr:turnOffWifi(complete_callback, fast)
    fast = fast or fast_teardown
    generation = generation + 1
    local my_generation = generation
    we_powered_on = false
    if keepWifiAlive then
        UIManager:unschedule(keepWifiAlive)
    end

    local function finish()
        timed("WiFiPower(0)", inkview.WiFiPower, 0)
        -- Some units keep the radio up after WiFiPower(0) alone; a no-op on others.
        if fast then netagentSync("wifi off") else netagentBackground("wifi off") end
        logger.info("PB Wi-Fi: radio powered down; QueryNetwork =", inkview.QueryNetwork(),
            "radio up =", radioUp())
        if complete_callback then
            complete_callback()
        end
    end

    if fast then
        return finish()
    end
    if not has_netagent then
        timed("NetDisconnect", inkview.NetDisconnect)
        return finish()
    end
    -- NOTE: NetDisconnect() just runs `netagent disconnect` and waits for it
    --       (3.7 s once on an InkPad Color 3), so run that ourselves.

    -- Same order (disconnect, then WiFiPower(0)), without blocking the UI on netagent.
    if not net_off_pending then
        os.remove(NET_OFF_MARKER)
        net_off_pending = true
        netagentBackground("disconnect", NET_OFF_MARKER)
    end
    UIManager:scheduleIn(0.25, function() afterNetOff(my_generation, finish) end)
end

-- Connecting is left to the stock NetConnect(). Field results from an InkPad
-- Color 3 (FW 6.10), see docs/:
--   * NetConnect() reaches a known network in ~1.5 s without any dialog, and
--     shows the system network picker otherwise. It blocks while it does so,
--     like stock.
--   * Everything else tried failed there: NetConnectSilent() blocked ~28 s
--     with no known network around; `netagent connect`/`connect_silent` run
--     from a shell exit after ~1 s without connecting (NetConnect() does more
--     than run netagent: suspend inhibition, waiting for the link, ...).
-- What *is* changed: a failed NetConnect() (no network, picker cancelled) is
-- reported, so the radio goes down right away instead of after the 45 s
-- connectivity check.
local NET_OFF_SYNC_WAIT = 5 -- seconds

function NetworkMgr:turnOnWifi(complete_callback, interactive)
    generation = generation + 1
    if not radioUp() then
        we_powered_on = true
    end

    -- A `netagent disconnect` from a turnOffWifi() just before must not race the
    -- connect. Rare (off then on within ~1 s), so a short blocking wait is fine.
    if net_off_pending then
        local waited = 0
        while lfs.attributes(NET_OFF_MARKER, "mode") ~= "file" and waited < NET_OFF_SYNC_WAIT do
            ffiutil.usleep(100 * 1000)
            waited = waited + 0.1
        end
        net_off_pending = false
        os.remove(NET_OFF_MARKER)
        logger.info("PB Wi-Fi: waited ~", waited, "s for netagent disconnect before connecting")
    end

    timed("WiFiPower(1)", inkview.WiFiPower, 1)
    if timed("NetConnect", inkview.NetConnect, nil) ~= C.NET_OK then
        logger.info("PB Wi-Fi: NetConnect failed (no known network, or picker cancelled)")
        -- Power down here rather than rely on the caller: enableWifi() & co.
        -- abort on `false` (a second turnOffWifi() is harmless), but plugins
        -- calling turnOnWifi() directly may ignore it.
        self:turnOffWifi()
        return false
    end
    if keepWifiAlive then keepWifiAlive() end
    if complete_callback then
        complete_callback()
    end
end

function NetworkMgr:isWifiOn()
    if radioUp() then return true end
    -- Once the interface is known, sysfs is authoritative (and cheap: this
    -- runs on every footer refresh). Until then, ask inkview.
    return detected_iface == nil and isAssociated()
end

function NetworkMgr:isConnected()
    -- stock_isConnected = isWifiOn() and hasDefaultRoute() (+ resolver reload);
    -- additionally require an actual association.
    return isAssociated() and stock_isConnected(self)
end

function NetworkMgr:getNetworkInterfaceName()
    return detectInterface() or detected_iface or "eth0"
end
NetworkMgr.interface = NetworkMgr:getNetworkInterfaceName()
NetworkMgr:queryNetworkState()

-- isWifiOn() is a couple of sysfs reads now.
Device.hasFastWifiStatusQuery = function() return true end

-- Leaving KOReader: undo what we did.
local function shouldPowerDown(setting)
    return we_powered_on and G_reader_settings:nilOrTrue(setting) and NetworkMgr:isWifiOn()
end

-- On PocketBook, Suspend means sleep, cover close or switching apps. The
-- firmware can freeze KOReader right after it (InkPad Color 3: immediately),
-- so power down synchronously, from the handler itself.
--
-- Exception: something reacting to the Suspend event (kosync auto sync) has
-- just brought Wi-Fi up to push progress. Then power down once that has
-- settled, as a best effort: on devices that freeze right away this only runs
-- on the next wake.
local SUSPEND_SETTLE_MAX = 20
local SUSPEND_GRACE = 4
local suspend_watch

local function cancelSuspendWatch()
    if suspend_watch then
        UIManager:unschedule(suspend_watch)
        suspend_watch = nil
    end
end

local function powerDownNow(reason)
    cancelSuspendWatch()
    logger.info("PB Wi-Fi:", reason, "- powering the radio down")
    fast_teardown = true
    NetworkMgr:disableWifi()
    fast_teardown = false
end

local function watchSuspend()
    cancelSuspendWatch()
    local waited = 0
    local settled = false
    suspend_watch = function()
        if not shouldPowerDown("pocketbook_wifi_off_on_suspend") then
            suspend_watch = nil
            return
        end
        if not settled then
            if (NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check)
                    and waited < SUSPEND_SETTLE_MAX then
                waited = waited + 1
                UIManager:scheduleIn(1, suspend_watch)
                return
            end
            settled = true
            UIManager:scheduleIn(SUSPEND_GRACE, suspend_watch)
            return
        end
        powerDownNow("sync on sleep/background done")
    end
    UIManager:scheduleIn(0, suspend_watch)
end

local orig_suspend = UIManager.event_handlers.Suspend
UIManager.event_handlers.Suspend = function(...)
    local was_connecting = NetworkMgr.pending_connection
    local ret
    if orig_suspend then ret = orig_suspend(...) end
    if shouldPowerDown("pocketbook_wifi_off_on_suspend") then
        if NetworkMgr.pending_connection and not was_connecting then
            logger.info("PB Wi-Fi: going to sleep/background while a sync connects, powering down once it's done")
            watchSuspend()
        else
            powerDownNow("going to sleep/background")
        end
    end
    return ret
end

-- Back in the foreground before a delayed power-down ran: leave Wi-Fi alone.
local orig_resume = UIManager.event_handlers.Resume
UIManager.event_handlers.Resume = function(...)
    cancelSuspendWatch()
    if orig_resume then return orig_resume(...) end
end

local orig_exit = Device.exit
Device.exit = function(...)
    if shouldPowerDown("pocketbook_wifi_off_on_exit") then
        logger.info("PB Wi-Fi: exiting, powering the radio down")
        NetworkMgr:turnOffWifi(nil, true) -- fast: no event loop left to wait in
    end
    return orig_exit(...)
end

-- kosync's manual push/pull brings Wi-Fi up through beforeWifiAction, but
-- never calls the matching afterWifiAction, so "Action when done with Wi-Fi"
-- is ignored. Bracket interactive syncs like newsdownloader does. Requests are
-- async (5 s timeout) and kosync also drains its queue and pulls on
-- NetworkConnected, so wait a bit before calling it.
local KOSYNC_SETTLE = 6
local kosync_done

pcall(userpatch.registerPatchPluginFunc, "kosync", function(KOSync)
    if KOSync._pb_wifi_bracketed then return end
    KOSync._pb_wifi_bracketed = true
    for __, name in ipairs({ "updateProgress", "getProgress" }) do
        local orig = KOSync[name]
        KOSync[name] = function(self, ensure_networking, interactive, ...)
            local ret = orig(self, ensure_networking, interactive, ...)
            -- The first call (offline) only starts connecting; the re-run
            -- once connected is the one that actually syncs.
            if interactive and NetworkMgr:getBeforeActionFlag() and NetworkMgr:isConnected() then
                if kosync_done then UIManager:unschedule(kosync_done) end
                kosync_done = function()
                    kosync_done = nil
                    logger.info("PB Wi-Fi: kosync done, running afterWifiAction")
                    NetworkMgr:afterWifiAction()
                end
                UIManager:scheduleIn(KOSYNC_SETTLE, kosync_done)
            end
            return ret
        end
    end
end)

-- Menu: Network -> "PocketBook: Wi-Fi off when leaving KOReader".
local function toggleItem(text, setting)
    return {
        text = text,
        checked_func = function() return G_reader_settings:nilOrTrue(setting) end,
        callback = function() G_reader_settings:flipNilOrTrue(setting) end,
    }
end

local orig_getMenuTable = NetworkMgr.getMenuTable
function NetworkMgr:getMenuTable(common_settings)
    orig_getMenuTable(self, common_settings)
    common_settings.network_pocketbook_wifi = {
        text = _("PocketBook: Wi-Fi off when leaving KOReader"),
        help_text = _([[Only applies when KOReader turned Wi-Fi on itself. Wi-Fi that was already on when KOReader started is left alone.]]),
        sub_item_table = {
            toggleItem(_("When going to background or sleep"), "pocketbook_wifi_off_on_suspend"),
            toggleItem(_("When exiting KOReader"), "pocketbook_wifi_off_on_exit"),
        },
    }
end

for __, mod in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
    local ok, order = pcall(require, mod)
    local network = ok and order and order.network
    if network then
        local pos = #network + 1
        for i, key in ipairs(network) do
            if key == "network_powersave" then pos = i + 1 end
        end
        table.insert(network, pos, "network_pocketbook_wifi")
    end
end

logger.info("PB Wi-Fi patch", PATCH_VERSION, "active; interface =", NetworkMgr.interface,
    "netagent =", has_netagent, "timeout =", TIMEOUT ~= "" and TIMEOUT or "none")
