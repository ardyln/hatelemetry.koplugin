-- Loads main.lua with fake KOReader modules to check which plugin instance owns
-- the periodic loop after switching between the file manager and the reader.

local scheduled

local function fake_ui()
    local ui = { events = {} }
    ui.menu = { registerToMainMenu = function() end }
    function ui:handleEvent(ev) self.events[#self.events + 1] = ev end
    return ui
end

local function load_plugin(settings)
    scheduled = {}
    local UIManager = {}
    function UIManager:scheduleIn(_, action, ...)
        scheduled[#scheduled + 1] = { action = action, args = { ... } }
    end
    function UIManager:unschedule(action)
        for i = #scheduled, 1, -1 do
            if scheduled[i].action == action then table.remove(scheduled, i) end
        end
    end

    local WidgetContainer = {}
    function WidgetContainer:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, { __index = self })
    end
    function WidgetContainer:new(o)
        o = setmetatable(o or {}, self)
        if o.init then o:init() end
        return o
    end

    local fakes = {
        ["gettext"] = function(s) return s end,
        ["ui/uimanager"] = UIManager,
        ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
        ["ui/widget/inputdialog"] = {},
        ["ui/widget/infomessage"] = {},
        ["ui/widget/container/widgetcontainer"] = WidgetContainer,
        ["device"] = { getPowerDevice = function() return {} end },
        ["ui/network/manager"] = { isConnected = function() return false end },
        ["logger"] = { info = function() end },
        ["ha_config"] = { host = "ha", port = 8123, webhook_id = "id", token = "" },
    }
    for name, mod in pairs(fakes) do
        package.loaded[name] = nil
        package.preload[name] = function() return mod end
    end
    package.loaded["main"] = nil
    _G.G_reader_settings = {
        readSetting = function() return settings end,
    }
    return require("main")
end

local function loop_owners()
    local owners = {}
    for _, task in ipairs(scheduled) do
        local inst = task.args[1]
        if inst and task.action == inst.pushLoop then owners[#owners + 1] = inst end
    end
    return owners
end

describe("periodic loop", function()
    it("moves to the newest instance when a book is opened", function()
        local HATelemetry = load_plugin({ enabled = true, loop_enabled = true, interval = 1 })
        HATelemetry:new{ ui = fake_ui() }               -- file manager
        local reader = HATelemetry:new{ ui = fake_ui() } -- reader

        local owners = loop_owners()
        assert.are.equal(1, #owners)
        assert.are.equal(reader, owners[1])
    end)

    it("sends page turns to the reader's UI", function()
        local HATelemetry = load_plugin({ enabled = true, loop_enabled = true, interval = 1 })
        local fm_ui, reader_ui = fake_ui(), fake_ui()
        HATelemetry:new{ ui = fm_ui }
        HATelemetry:new{ ui = reader_ui }

        loop_owners()[1]:commandDeps().turn_page(1)
        assert.are.equal(0, #fm_ui.events)
        assert.are.equal("GotoViewRel", reader_ui.events[1].name)
        assert.are.equal(1, reader_ui.events[1].args[1])
    end)

    it("is not scheduled when periodic updates are off", function()
        local HATelemetry = load_plugin({ enabled = true, loop_enabled = false })
        HATelemetry:new{ ui = fake_ui() }
        assert.are.equal(0, #loop_owners())
    end)
end)
