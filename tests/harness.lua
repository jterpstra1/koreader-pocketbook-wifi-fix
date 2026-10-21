--[[
Simulation harness for patches/2-pocketbook-wifi.lua.

Loads KOReader's real frontend/ui/network/manager.lua and the real stock
PocketBook:initNetworkManager() (extracted from frontend/device/pocketbook/device.lua)
on top of a simulated PocketBook network stack (inkview + netagent + sysfs),
then applies the patch. Run via tests/run.py (LuaJIT through lupa).

Globals expected from the runner: KO_DIR (KOReader checkout), PATCH (patch path).
--]]

local ffi = require("ffi")
ffi.cdef[[
static const unsigned NET_CONNECTED = 3840;
static const unsigned NET_OK = 0;
static const int POCKETBOOK_VERSION = 610;
]]

---------------------------------------------------------------- simulated device
local sim = {}

function sim.reset(opts)
    opts = opts or {}
    sim.now = 0
    sim.radio = opts.radio or false            -- WiFiPower state
    sim.agent = opts.agent or false            -- netagent / wpa_supplicant running
    sim.associated = opts.associated or false
    sim.in_range = opts.in_range ~= false      -- a known network is around
    sim.dialog_result = opts.dialog_result     -- true: user picks a network; false: cancels
    sim.has_silent = opts.has_silent ~= false  -- libinkview exports NetConnectSilent
    sim.radio_off_needs_wifi_off = opts.radio_off_needs_wifi_off or false
    -- Default: the InkPad Color 3 behaviour measured from crash.logs (NetConnect
    -- reaches a known network silently; picker only when none is in range).
    sim.netconnect_silent_in_range = opts.netconnect_silent_in_range ~= false
    sim.iface_down_while_connecting = opts.iface_down_while_connecting or false
    sim.connect_delay = opts.connect_delay
    sim.connect_marker = nil
    sim.net_disabled = opts.net_disabled or false
    sim.accept_enable_prompt = opts.accept_enable_prompt or false
    sim.enable_prompts = 0
    sim.blocking = 0        -- blocking inkview connect calls + synchronous netagent runs
    sim.blocking_connect = 0 -- blocking NetConnect/NetConnectSilent calls only (the ~28 s freeze)
    sim.files = {}
    sim.associate_at = nil
    sim.dialogs = 0
    sim.commands = {}
    sim.events = {}
    sim.pings = 0
    sim.tasks = {}
    sim.settings = {}
    sim.plugin_patches = {}
end

-- A running `netagent connect`/`connect_silent`: touches its marker (if any) when it exits.
local function connect_done()
    if sim.connect_marker then
        sim.files[sim.connect_marker] = true
        sim.connect_marker = nil
    end
end

local function tick_assoc()
    if sim.associate_at and sim.now >= sim.associate_at then
        sim.associate_at = nil
        if sim.radio and sim.agent and sim.in_range then sim.associated = true end
        connect_done()
    end
end

-- InkPad Color 3: the interface isn't (reported) up while netagent is connecting.
local function iface_up()
    if not sim.radio then return false end
    if sim.iface_down_while_connecting and sim.associate_at then return false end
    return true
end
sim.iface_up = iface_up

local inkview = {
    WiFiPower = function(on)
        if on == 1 then sim.radio = true
        elseif not sim.radio_off_needs_wifi_off then
            sim.radio = false; sim.associated = false
        end
        return 0
    end,
    NetConnect = function()
        sim.blocking = sim.blocking + 1
        sim.blocking_connect = sim.blocking_connect + 1
        if sim.net_disabled then
            sim.enable_prompts = sim.enable_prompts + 1
            if not sim.accept_enable_prompt then return -35 end -- NET_EDISABLED
            sim.net_disabled = false
        end
        -- InkPad Color 3 (FW 6.10): NetConnect -> `netagent connect` reaches a
        -- known network in ~1.5 s without any dialog; the picker only shows otherwise.
        if sim.netconnect_silent_in_range and sim.radio and sim.in_range then
            sim.agent = true; sim.associated = true
            return 0
        end
        sim.dialogs = sim.dialogs + 1
        if sim.dialog_result and sim.radio then
            sim.agent = true; sim.associated = true
            return 0
        end
        return -1
    end,
    -- Runs `netagent disconnect` and waits for it (took 3.7 s once on the InkPad).
    NetDisconnect = function() sim.blocking = sim.blocking + 1; sim.associated = false; return 0 end,
    QueryNetwork = function()
        tick_assoc()
        return sim.associated and 3840 or 0
    end,
    NetMgrPing = function() sim.pings = sim.pings + 1; return 0 end,
}
setmetatable(inkview, { __index = function(_, k)
    if k == "NetConnectSilent" and sim.has_silent then
        return function()
            sim.blocking = sim.blocking + 1 -- ~28 s freeze on InkPad Color 3
            sim.blocking_connect = sim.blocking_connect + 1
            if not sim.agent then return -12 end
            if sim.radio and sim.in_range then sim.associated = true; return 0 end
            return -1
        end
    end
    error("undefined symbol: " .. tostring(k))
end })

local real_io_open = io.open
io.open = function(path, mode)
    local iface = path:match("^/sys/class/net/([^/]+)/flags$")
    if iface then
        tick_assoc()
        if iface == "eth0" and iface_up() then
            return { read = function() return "0x1003" end, close = function() end }
        end
        return nil
    end
    return real_io_open(path, mode)
end

-- Background commands take effect a little later, like on the device.
local function later(delay, fn)
    table.insert(sim.tasks, { at = sim.now + delay, fn = fn, args = { n = 0 } })
end

os.execute = function(cmd)
    table.insert(sim.commands, cmd)
    if cmd:find("timeout -?t? ?1 true") then return 0 end
    local bg = cmd:find("&%s*$") ~= nil
    local marker = cmd:match("touch (%S+)%)")
    if cmd:find("netagent", 1, true) and not bg then sim.blocking = sim.blocking + 1 end
    local is_connect = cmd:find("netagent connect", 1, true) ~= nil
    local function apply()
        if cmd:find("netagent disconnect", 1, true) then sim.associated = false end
        -- `net off` also disables networking system-wide (the PocketBook Wi-Fi
        -- setting): NetConnect() then asks "The application needs an Internet
        -- connection" first.
        if cmd:find("net off", 1, true) then sim.agent = false; sim.associated = false; sim.net_disabled = true end
        if cmd:find("net on", 1, true) then sim.net_disabled = false end
        if cmd:find("wifi off", 1, true) then sim.radio = false; sim.associated = false end
        if cmd:find("net on", 1, true) then sim.agent = true end
        if is_connect then
            sim.connect_marker = marker
            if not sim.radio then
                connect_done()
            elseif cmd:find("netagent connect_silent", 1, true) then
                -- Never shows UI. Connects when a known network is around,
                -- otherwise gives up after ~28 s.
                sim.agent = true
                if sim.in_range then
                    sim.associate_at = sim.now + (sim.connect_delay or 2)
                else
                    later(28, connect_done)
                end
            else
                sim.agent = true
                if sim.in_range then
                    sim.associate_at = sim.now + (sim.connect_delay or 1.5)
                else
                    -- netagent opens net_configurator.app (the picker) itself,
                    -- and exits once it's closed.
                    sim.dialogs = sim.dialogs + 1
                    later(5, function()
                        if sim.dialog_result then
                            if sim.radio then sim.associated = true end
                        else
                            -- Cancelling the picker: netagent "wifi off".
                            sim.radio = false; sim.associated = false
                        end
                        connect_done()
                    end)
                end
            end
        elseif marker then
            sim.files[marker] = true
        end
    end
    if bg then later(0.5, apply) else apply() end
    return 0
end

local real_os_remove = os.remove
os.remove = function(path)
    if sim.files[path] then sim.files[path] = nil; return true end
    return real_os_remove(path)
end

---------------------------------------------------------------- module stubs
local function stub(name, mod) package.loaded[name] = mod; return mod end

local function noop() end
local Widget = { new = function(cls, o) o = o or {}; o._cls = cls; return o end }

stub("logger", { dbg = noop, info = noop, warn = noop, err = noop })
stub("gettext", function(s) return s end)
stub("ui/bidi", {})
stub("ui/widget/confirmbox", Widget)
stub("ui/widget/multiconfirmbox", Widget)
stub("ui/widget/infomessage", Widget)
stub("ui/event", { new = function(_, name) return { name = name } end })
stub("datastorage", { getSettingsDir = function() return "/tmp" end, getDataDir = function() return "/tmp" end })
stub("luasettings", { open = function() return { readSetting = noop } end })
stub("ffi/util", {
    template = function(s) return s end,
    -- A blocking sleep: let simulated time (and background commands) move on.
    usleep = function(us) sim.run(us / 1e6) end,
})
stub("ui/time", { now = function() return sim.now end, to_ms = function(t) return t * 1000 end })
stub("ffi/posix_h", true)
stub("util", {
    pathExists = function() return false end,
    fileExists = function(path) return path == "/ebrmain/bin/netagent" end,
    directoryExists = function(path) return path == "/sys/class/net/eth0/wireless" and iface_up() end,
    readFromFile = function(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local s = f:read("*a"); f:close(); return s
    end,
})
stub("ffi/inkview", inkview)
stub("libs/libkoreader-lfs", { attributes = function(path, what)
    if path == "/ebrmain/bin/netagent" then return "file" end
    if path == "/usr/bin/timeout" then return "file" end
    if path == "/sys/class/net/eth0/wireless" and iface_up() then return "directory" end
    if sim.files[path] then return "file" end
    return nil
end })
stub("socket", { udp = function()
    return {
        setpeername = function() if sim.associated then return 1 end return nil, "Network is unreachable" end,
        close = noop,
    }
end, dns = { toip = function()
    if sim.associated then return "192.0.2.1" end
    return nil, "host not found"
end } })
stub("ui/elements/filemanager_menu_order", { network = { "network_wifi", "network_proxy", "network_powersave", "network_restore" } })
stub("ui/elements/reader_menu_order", { network = { "network_wifi", "network_powersave" } })

-- UIManager with a simulated clock.
local UIManager = {
    event_handlers = {},
    shown = {},
}
function UIManager:scheduleIn(secs, fn, ...)
    table.insert(sim.tasks, { at = sim.now + secs, fn = fn, args = { n = select("#", ...), ... } })
end
function UIManager:nextTick(fn, ...) self:scheduleIn(0, fn, ...) end
function UIManager:unschedule(fn)
    for i = #sim.tasks, 1, -1 do
        if sim.tasks[i].fn == fn then table.remove(sim.tasks, i) end
    end
end
function UIManager:broadcastEvent(ev) table.insert(sim.events, ev.name) end
function UIManager:show(w) self.shown[w] = true end
function UIManager:close(w) self.shown[w] = nil end
function UIManager:forceRePaint() end
function UIManager:askForRestart() end
stub("ui/uimanager", UIManager)

function sim.run(seconds)
    local stop = sim.now + seconds
    while true do
        table.sort(sim.tasks, function(a, b) return a.at < b.at end)
        local t = sim.tasks[1]
        if not t or t.at > stop then break end
        table.remove(sim.tasks, 1)
        sim.now = math.max(sim.now, t.at)
        t.fn(unpack(t.args, 1, t.args.n))
    end
    sim.now = stop
end

local function settings_store()
    local s = {}
    function s:readSetting(k) return sim.settings[k] end
    function s:saveSetting(k, v) sim.settings[k] = v end
    function s:isTrue(k) return sim.settings[k] == true end
    function s:nilOrTrue(k) return sim.settings[k] == nil or sim.settings[k] == true end
    function s:makeTrue(k) sim.settings[k] = true end
    function s:makeFalse(k) sim.settings[k] = false end
    function s:flipNilOrTrue(k) sim.settings[k] = not s:nilOrTrue(k) end
    function s:flipNilOrFalse(k) sim.settings[k] = not s:isTrue(k) end
    return s
end
G_reader_settings = settings_store()
G_defaults = settings_store()

---------------------------------------------------------------- stock PocketBook backend
local function read_file(path)
    local f = assert(real_io_open(path, "r")); local s = f:read("*a"); f:close(); return s
end

local function stock_initNetworkManager()
    local src = read_file(KO_DIR .. "/frontend/device/pocketbook/device.lua")
    local body = src:match("(function PocketBook:initNetworkManager%(NetworkMgr%).-\nend)\n")
    assert(body, "could not extract PocketBook:initNetworkManager")
    local env = setmetatable({
        PocketBook = {}, inkview = inkview, C = ffi.C, ffi = ffi,
        band = require("bit").band, UIManager = UIManager, util = package.loaded.util,
        logger = package.loaded.logger,
    }, { __index = _G })
    local chunk = assert(loadstring(body, "=stock_pb_net"))
    setfenv(chunk, env)
    chunk()
    return env.PocketBook.initNetworkManager
end

local Device = {
    isPocketBook = function() return true end,
    hasWifiToggle = function() return true end,
    hasSeamlessWifiToggle = function() return true end,
    hasWifiRestore = function() return false end,
    hasWifiManager = function() return false end,
    hasFastWifiStatusQuery = function() return false end,
    isKindle = function() return false end,
    isAndroid = function() return false end,
    isEmulator = function() return false end,
    exited = 0,
}
Device.initNetworkManager = function(self, mgr) return stock_initNetworkManager()(self, mgr) end
Device.exit = function() Device.exited = Device.exited + 1 end
stub("device", Device)

-- Real userpatch.getUpValue, without the rest of userpatch.lua.
stub("userpatch", { getUpValue = function(func_obj, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(func_obj, i)
        if not n then return nil end
        if n == name then return v, i end
        i = i + 1
    end
end, registerPatchPluginFunc = function(name, fn)
    sim.plugin_patches[name] = sim.plugin_patches[name] or {}
    table.insert(sim.plugin_patches[name], fn)
end })

---------------------------------------------------------------- loading
function sim.load(patched)
    package.loaded["ui/network/manager"] = nil
    sim.suspended, sim.on_suspend = 0, nil
    UIManager.event_handlers = {
        -- Stand-in for PocketBook's handler, which broadcasts Suspend (kosync listens to it).
        Suspend = function()
            sim.suspended = sim.suspended + 1
            if sim.on_suspend then sim.on_suspend() end
        end,
        Resume = function() end,
    }
    package.path = KO_DIR .. "/frontend/?.lua;" .. package.path
    local mgr = dofile(KO_DIR .. "/frontend/ui/network/manager.lua")
    package.loaded["ui/network/manager"] = mgr
    if patched and not UPSTREAM then dofile(PATCH) end
    return mgr
end

sim.Device = Device
sim.UIManager = UIManager
return sim
