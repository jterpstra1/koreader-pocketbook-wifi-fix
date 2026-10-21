-- Scenarios for the PocketBook Wi-Fi patch. Run via tests/run.py.
-- The simulated device defaults to the InkPad Color 3 (FW 6.10) behaviour
-- measured from real crash.logs: NetConnect() reaches a known network in
-- ~1.5 s without a dialog, and shows the network picker when none is in range.
local sim = dofile(TESTS_DIR .. "/harness.lua")

-- Userpatch-only behaviour, not part of upstream/pocketbook-wifi.diff.
local USERPATCH_ONLY = {
    "^stock", "own menu", "ordered after", "background/sleep", "Suspend handler",
    "left alone", "exit powers", "can be disabled", "resume cancels", "kosync",
    "manual push", "hasFastWifiStatusQuery", "^sleep:", "^exit:",
    -- Upstream relies on the documented contract (callers abort on `false`).
    "caller ignores the result", "single disconnect",
    -- Upstream keeps turn-off synchronous (netagent returned in ~1 s on the InkPad).
    "turning off makes no blocking",
}

local results, failed = {}, 0
local function check(name, cond, detail)
    if UPSTREAM then
        for __, pattern in ipairs(USERPATCH_ONLY) do
            if name:find(pattern) then return end
        end
    end
    table.insert(results, (cond and "PASS " or "FAIL ") .. name .. (cond and "" or ("  -- " .. tostring(detail or ""))))
    if not cond then failed = failed + 1 end
end
local function has(list, item)
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end
local function fresh(patched, opts)
    sim.reset(opts)
    sim.Device.exit = function() sim.Device.exited = sim.Device.exited + 1 end
    sim.Device.exited = 0
    sim.Device.hasFastWifiStatusQuery = function() return false end
    sim.Device._beforeSuspend = function()
        sim.suspended = sim.suspended + 1
        if sim.on_suspend then sim.on_suspend() end
    end
    sim.Device._afterResume = function() end
    return sim.load(patched)
end

-- Mimics KOSync:updateProgress: offline -> willRerunWhenOnline, online -> push.
local function fakeKOSync(mgr)
    local KOSync = { pushes = 0 }
    function KOSync:updateProgress(ensure_networking, interactive)
        if ensure_networking and mgr:willRerunWhenOnline(function() self:updateProgress(ensure_networking, interactive) end) then
            return
        end
        self.pushes = self.pushes + 1
    end
    function KOSync:getProgress() end
    for __, fn in ipairs(sim.plugin_patches.kosync or {}) do fn(KOSync) end
    return KOSync
end

---------------------------------------------------------------- stock: the bug
do
    local mgr = fresh(false, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    check("stock: connects without dialog", sim.associated and sim.dialogs == 0)
    mgr:toggleWifiOff(nil, true)
    sim.run(3)
    check("stock: BUG reproduced, radio still on after 'off'", sim.radio == true and not sim.associated)
    check("stock: BUG reproduced, KOReader reports Wi-Fi off", mgr:isWifiOn() == false)

    mgr = fresh(false, {})
    sim.settings.wifi_enable_action = "turn_on"
    sim.settings.wifi_disable_action = "turn_off"
    local kosync = fakeKOSync(mgr)
    kosync:updateProgress(true, true)
    sim.run(600)
    check("stock: BUG reproduced, radio on 10 min after manual push despite 'turn off'", kosync.pushes == 1 and sim.radio == true)

    mgr = fresh(false, {})
    sim.settings.wifi_enable_action = "turn_on"
    sim.on_suspend = function() mgr:willRerunWhenOnline(function() end) end
    sim.UIManager.event_handlers.Suspend()
    sim.run(600)
    check("stock: BUG reproduced, radio on 10 min after kosync suspend push", sim.radio == true)

    mgr = fresh(false, { in_range = false, dialog_result = false })
    mgr:toggleWifiOn(nil, false, true)
    sim.run(12)
    check("stock: radio still on 12 s after a cancelled picker", sim.radio == true)
end

---------------------------------------------------------------- turning on
do
    local mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    check("on: connects without dialog", sim.associated and sim.dialogs == 0)
    check("on: exactly one blocking call (NetConnect, like stock)", sim.blocking_connect == 1 and sim.blocking == 1, sim.blocking)
    check("on: NetworkConnected broadcast", has(sim.events, "NetworkConnected"))
    check("on: pending state cleared", mgr.pending_connection == false and mgr.pending_connectivity_check == false)
    sim.run(65)
    check("on: keepalive pings while connected", sim.pings >= 2, sim.pings)

    -- No known network, the user cancels the picker.
    mgr = fresh(true, { in_range = false, dialog_result = false })
    mgr:toggleWifiOn(nil, false, true)
    sim.run(2)
    check("on: cancelled picker powers the radio down within ~2 s", sim.dialogs == 1 and sim.radio == false
        and mgr.pending_connection == false and mgr.pending_connectivity_check == false)

    -- Same, but from a caller that ignores turnOnWifi()'s return value (e.g. a
    -- plugin's own Wi-Fi toggle): the radio must still go down.
    mgr = fresh(true, { in_range = false, dialog_result = false })
    mgr:turnOnWifi(function() end, true)
    sim.run(2)
    check("on: failed connect powers down even if the caller ignores the result", sim.radio == false)

    -- And with a caller that does abort: still exactly one teardown.
    mgr = fresh(true, { in_range = false, dialog_result = false })
    mgr:toggleWifiOn(nil, false, true)
    sim.run(2)
    local disconnects = 0
    for __, cmd in ipairs(sim.commands) do
        if cmd:find("netagent disconnect", 1, true) then disconnects = disconnects + 1 end
    end
    check("on: failed connect + caller abort runs a single disconnect", disconnects == 1, disconnects)

    -- No known network, the user picks one in the picker.
    mgr = fresh(true, { in_range = false, dialog_result = true })
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    check("on: network picked in the picker connects", sim.associated and has(sim.events, "NetworkConnected"))

    -- Off, then on again later: no "needs an Internet connection" prompt.
    mgr = fresh(true, { radio = true, agent = true, associated = true })
    mgr:toggleWifiOff(nil, true)
    sim.run(5)
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    check("on: no 'needs an Internet connection' prompt after our own 'off'", sim.enable_prompts == 0, sim.enable_prompts)
    check("on: connects after our own 'off'", sim.associated)

    -- Off then on straight away: the background teardown must not race the connect.
    mgr = fresh(true, { radio = true, agent = true, associated = true })
    mgr:toggleWifiOff(nil, true)
    mgr:toggleWifiOn(nil, false, true)
    sim.run(5)
    check("on: on right after off ends up connected", sim.associated and sim.radio)
end

---------------------------------------------------------------- turning off
do
    local mgr = fresh(true, { radio = true, agent = true, associated = true })
    mgr:toggleWifiOff(nil, true)
    check("off: turning off makes no blocking call", sim.blocking == 0, sim.blocking)
    sim.run(2)
    check("off: radio down and disconnected", sim.radio == false and not sim.associated)
    check("off: networking not disabled system-wide (no 'net off')", sim.net_disabled == false)
    check("off: isWifiOn false", mgr:isWifiOn() == false)
    check("off: NetworkDisconnected broadcast", has(sim.events, "NetworkDisconnected"))

    -- Units where WiFiPower(0) alone doesn't power down.
    mgr = fresh(true, { radio = true, agent = true, associated = true, radio_off_needs_wifi_off = true })
    mgr:turnOffWifi()
    sim.run(2)
    check("off: 'netagent wifi off' covers stubborn units", sim.radio == false)
end

---------------------------------------------------------------- state reporting
do
    local mgr = fresh(true, { radio = true, agent = true, associated = false })
    check("state: isWifiOn true when radio up but unassociated", mgr:isWifiOn() == true)
    check("state: isConnected false when unassociated", mgr:isConnected() == false)
    mgr:queryNetworkState()
    check("state: menu sees on-but-disconnected state", mgr.is_wifi_on and not mgr.is_connected)

    mgr = fresh(true, { radio = true })
    check("state: interface is eth0", mgr:getNetworkInterfaceName() == "eth0" and mgr.interface == "eth0")
    check("state: hasFastWifiStatusQuery", sim.Device.hasFastWifiStatusQuery() == true)
    local cs = {}
    mgr:getMenuTable(cs)
    check("state: 'Disable Wi-Fi when inactive' now offered", cs.network_powersave ~= nil)
    check("state: own menu entry present", cs.network_pocketbook_wifi ~= nil)
    local order = require("ui/elements/filemanager_menu_order").network
    check("state: own menu entry ordered after powersave", order[4] == "network_pocketbook_wifi", table.concat(order, ","))
end

---------------------------------------------------------------- manual kosync push
do
    local mgr = fresh(true, {})
    sim.settings.wifi_enable_action = "turn_on"
    sim.settings.wifi_disable_action = "turn_off"
    local kosync = fakeKOSync(mgr)
    kosync:updateProgress(true, true)
    sim.run(3)
    check("manual push: connects and pushes", kosync.pushes == 1 and sim.dialogs == 0)
    check("manual push: radio still on right after push", sim.radio == true)
    sim.run(8)
    check("manual push: honours 'turn off when done'", sim.radio == false)

    mgr = fresh(true, {})
    sim.settings.wifi_enable_action = "turn_on"
    sim.settings.wifi_disable_action = "leave_on"
    kosync = fakeKOSync(mgr)
    kosync:updateProgress(true, true)
    sim.run(15)
    check("manual push: honours 'leave on'", kosync.pushes == 1 and sim.radio == true)

    mgr = fresh(true, { radio = true, agent = true, associated = true })
    sim.settings.wifi_disable_action = "turn_off"
    kosync = fakeKOSync(mgr)
    kosync:updateProgress(true, true)
    sim.run(15)
    check("manual push: leaves pre-existing Wi-Fi on", kosync.pushes == 1 and sim.radio == true)

    -- Away from home: the picker shows (the user asked for the push); cancel it.
    mgr = fresh(true, { in_range = false, dialog_result = false })
    sim.settings.wifi_enable_action = "turn_on"
    sim.settings.wifi_disable_action = "turn_off"
    kosync = fakeKOSync(mgr)
    kosync:updateProgress(true, true)
    sim.run(2)
    check("manual push: away from home, cancelled picker -> no push, radio off, no 45 s wait",
        kosync.pushes == 0 and sim.dialogs == 1 and sim.radio == false and mgr.pending_connection == false)
end

---------------------------------------------------------------- leaving KOReader
-- On the InkPad Color 3 the firmware freezes KOReader right after the Suspend
-- event (crash.log: nothing logged between "Inhibiting user input" and the
-- wake), so anything scheduled for later doesn't run before sleep.
do
    local mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.UIManager.event_handlers.Suspend()
    check("sleep: radio down before KOReader is frozen (no time passes)", sim.radio == false)
    check("sleep: fast power-down makes no slow blocking call", sim.slow_blocking == 0, sim.slow_blocking)

    -- A plugin installing its own Suspend handler after the patch loaded (the
    -- suspected 0.6.1 field failure): still powered down, via _beforeSuspend.
    mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.UIManager.event_handlers.Suspend = function() sim.Device:_beforeSuspend() end
    sim.UIManager.event_handlers.Suspend()
    check("sleep: radio down even if a plugin replaced the Suspend handler", sim.radio == false)

    -- Same, with a connectivity check still pending (flaky hotspot: associated, no route yet).
    mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    mgr.pending_connectivity_check = true
    sim.UIManager.event_handlers.Suspend()
    check("sleep: radio down even with a stale connectivity check pending", sim.radio == false)

    mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.Device.exit()
    check("exit: fast power-down, no slow netagent disconnect", sim.radio == false and sim.slow_blocking == 0, sim.slow_blocking)
end

do
    local mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.UIManager.event_handlers.Suspend()
    check("leaving: original Suspend handler still called", sim.suspended == 1)
    sim.run(8)
    check("leaving: background/sleep powers down radio KOReader enabled", sim.radio == false)

    mgr = fresh(true, { radio = true, agent = true, associated = true })
    sim.UIManager.event_handlers.Suspend()
    sim.run(30)
    check("leaving: pre-existing Wi-Fi left alone on background", sim.radio == true)
    sim.Device.exit()
    check("leaving: pre-existing Wi-Fi left alone on exit", sim.radio == true and sim.Device.exited == 1)

    mgr = fresh(true, {})
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.Device.exit()
    check("leaving: exit powers down radio KOReader enabled", sim.radio == false and sim.Device.exited == 1)

    mgr = fresh(true, {})
    sim.settings.pocketbook_wifi_off_on_suspend = false
    mgr:toggleWifiOn(nil, false, true)
    sim.run(3)
    sim.UIManager.event_handlers.Suspend()
    sim.run(30)
    check("leaving: background power-down can be disabled", sim.radio == true)

    -- kosync auto-sync connecting on Suspend, then woken up again within a second:
    -- the delayed power-down is cancelled (kosync pulls on resume).
    mgr = fresh(true, {})
    sim.settings.wifi_enable_action = "turn_on"
    sim.on_suspend = function() mgr:willRerunWhenOnline(function() end) end
    sim.UIManager.event_handlers.Suspend()
    sim.run(1)
    sim.UIManager.event_handlers.Resume()
    sim.run(30)
    check("leaving: resume cancels the delayed (auto-sync) power-down", sim.radio == true)

    -- kosync auto-sync: the Suspend event itself brings Wi-Fi up to push progress.
    mgr = fresh(true, {})
    sim.settings.wifi_enable_action = "turn_on"
    local pushed = false
    sim.on_suspend = function() mgr:willRerunWhenOnline(function() pushed = true end) end
    sim.UIManager.event_handlers.Suspend()
    sim.run(3)
    check("leaving: kosync suspend push still happens", pushed and sim.associated)
    check("leaving: kosync radio not cut mid-push", sim.radio == true)
    sim.run(10)
    check("leaving: kosync radio off after suspend push", sim.radio == false)
end

return table.concat(results, "\n"), failed
