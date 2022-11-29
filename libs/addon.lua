local __namespace, __module = ...

local Array = __module.Array --- @class Array

local module = {} --- @class Addon

local frame = CreateFrame("Frame", nil)
local onLoadHooks = Array.new()
local onUpdateHooks = Array.new()
local debugValues = {} --- @type table<string, unknown>
local listeners = {} --- @type table<WowEvent | any, Array>
local stateData = Array.new()
local hooks = Array.new()
local updatePending = false

--- @class ReactiveData
--- @field get fun(): unknown
--- @field set fun(newValue: any)
--- @field ref integer

--- @class ReactiveSavedVariable : ReactiveData
--- @field globalName string
--- @field varName string
--- @field defaultValue unknown

--- comment
local function runHooks()
  updatePending = false

  hooks:forEach(
    function(effect)
      local deps = effect.deps
      local fn = effect.fn

      local diff = false

      if deps == nil then
        diff = true
      elseif Array.isArray(deps) then
        deps:forEach(
          function(dep)
            local oldValue = dep.val
            local newValue = dep.get()

            if oldValue ~= newValue then
              diff = true
              dep.val = newValue
            end
          end
        )
      end

      if diff then
        fn()
      end
    end
  )
end

--- comment
local function triggerUpdate()
  if updatePending then
    return
  end

  updatePending = true
  module.nextTick(runHooks)
end

--- comment
--- @param value any
--- @return ReactiveData
function module.useState(value)
  stateData:push(value)

  local stateIndex = stateData:length()

  local function set(newValue)
    stateData[stateIndex] = newValue
    triggerUpdate()
  end

  local function get()
    return stateData[stateIndex]
  end

  return { get = get, set = set, ref = stateIndex }
end

--- comment
--- @param fn function
--- @param deps ReactiveData[]
function module.useEffect(fn, deps)
  local toPush = { fn = fn, deps = nil }

  if type(deps) == "table" then
    toPush.deps = Array.new(deps):map(
      function(dep)
        return { val = nil, get = dep.get, ref = dep.ref }
      end
    )
  end

  hooks:push(toPush)
end

--- comment
--- @param fn function
--- @param deps ReactiveData[]
function module.useMemo(fn, deps)
end

--- comment
function module.useContext()
end

--- comment
--- @param globalName string
--- @param varName string
--- @param defaultValue any
--- @return ReactiveSavedVariable
function module.useSavedVariable(globalName, varName, defaultValue)
  local toRet = module.useState(defaultValue)

  toRet.globalName = globalName
  toRet.varName = varName
  toRet.defaultValue = defaultValue

  module.onLoad(
    function()
      _G[globalName] = _G[globalName] or {}

      if (_G[globalName][varName] == nil) then
        _G[globalName][varName] = defaultValue
      end

      toRet.set(_G[globalName][varName])
    end
  )

  module.useEffect(
    function()
      _G[globalName][varName] = toRet.get()
    end, { toRet }
  )

  return toRet
end

--- comment
--- @param fn function
--- @param events WowEvent[]
--- @param once boolean?
function module.useEvent(fn, events, once)
  local eventsArray = Array.new(events or {})
  once = once or false

  local unsub = nil

  local function handler(...)
    local result = fn(...)

    if once then
      unsub()
    end

    return result
  end

  unsub = function()
    eventsArray:forEach(
      function(event)
        listeners[event] = listeners[event]:filter(
          function(h)
            return h ~= handler
          end
        )

        if listeners[event]:length() == 0 then
          frame:UnregisterEvent(event)
        end
      end
    )
  end

  eventsArray:forEach(
    function(event)
      if not listeners[event] then
        frame:RegisterEvent(event)
        listeners[event] = Array.new()
      end

      listeners[event]:push(handler)
    end
  )

  return unsub
end

--- comment
--- @param fn fun(arg1?: string, arg2?: string, arg3?: string)
--- @param aliases string[]
function module.useSlashCmd(fn, aliases)
  local cmdsArray = Array.new(aliases)
  local name = aliases[1]:upper()

  cmdsArray:forEach(
    function(cmd, index)
      _G["SLASH_" .. name .. index] = "/" .. cmd
    end
  )

  SlashCmdList[name] = function(msg)
    local args = {}

    for arg in msg:gmatch("%S+") do
      table.insert(args, arg)
    end

    fn(unpack(args))
  end
end

--- comment
--- @param fnName string
--- @param fn function
--- @param hookType? "function" | "secure-function" | "widget" | "secure-widget"
--- @param srcTable? table
--- @param once? boolean
function module.useHook(fnName, fn, hookType, srcTable, once)
  hookType = hookType or "function"
  srcTable = srcTable or _G

  local unhook = nil

  local enabled = true
  local oldFn = nil
  local hookProxy = {}
  local hookFn = function(...)
    if once then
      unhook()
    end

    return hookProxy(...)
  end

  setmetatable(
    hookProxy, {
      __call = function(...)
        if not enabled and oldFn then
          return oldFn(...)
        elseif not enabled then
          return
        end

        return fn(...)
      end,
      __index = function(t, k)
        if k == "__enabled" then
          return enabled
        elseif k == "__oldFn" then
          return oldFn
        elseif k == "__srcTable" then
          return srcTable
        elseif type(srcTable[k]) == "function" then
          return function(_, ...)
            return srcTable[k](srcTable, ...)
          end
        else
          return srcTable[k]
        end
      end,
      __newindex = function(t, k, v)
        if k == "__enabled" then
          enabled = v
        elseif k == "__oldFn" then
          oldFn = v
        else
          srcTable[k] = v
        end
      end,
    }
  )

  unhook = function()
    enabled = false
  end

  if hookType == "function" then
    oldFn = srcTable[fnName]
    srcTable[fnName] = hookFn
  elseif hookType == "secure-function" and srcTable then
    hooksecurefunc(srcTable, fnName, hookFn)
  elseif hookType == "secure-function" then
    hooksecurefunc(fnName, hookFn)
  elseif hookType == "widget" then
    oldFn = srcTable:GetScript(fnName)
    srcTable:SetScript(fnName, hookFn)
  elseif hookType == "secure-widget" then
    srcTable:HookScript(fnName, hookFn)
  end

  return unhook
end

--- comment
--- @param label string
--- @param dep ReactiveData[]
function module.useDebugValue(label, dep)
  module.useEffect(
    function()
      debugValues[label] = dep.get()
    end, { dep }
  )
end

--- comment
--- @param fn function
--- @param deltaTime? number
function module.nextTick(fn, deltaTime)
  deltaTime = deltaTime or 0
  C_Timer.After(deltaTime, fn)
end

--- comment
--- @param msg any
function module.print(msg)
  print("|cffff8000" .. __namespace .. ": |r" .. tostring(msg))
end

--- comment
--- @param fn function
function module.onLoad(fn)
  onLoadHooks:push(fn)
end

--- comment
--- @param fn function
function module.onInit(fn)
  fn()
end

--- comment
--- @param fn function
function module.onUpdate(fn)
  onUpdateHooks:push(fn)

  if not frame:GetScript("OnUpdate") then
    frame:SetScript(
      "OnUpdate", function(frame, delta)
        onUpdateHooks:forEach(
          function(fn)
            fn(delta)
          end
        )
      end
    )
  end
end

frame:SetScript(
  "OnEvent", function(frame, event, ...)
    local handlers = listeners[event] or Array.new()
    local args = { ... }

    handlers:forEach(
      function(handler)
        handler(event, unpack(args))
      end
    )
  end
)

module.useEvent(
  function(evetName, addonName)
    if addonName == __namespace then
      onLoadHooks:forEach(
        function(fn)
          fn()
        end
      )

      triggerUpdate()

      module.nextTick(
        function()
          if next(debugValues) == nil then
            return
          end

          if not IsAddOnLoaded("Blizzard_DebugTools") then
            UIParentLoadAddOn("Blizzard_DebugTools")
          end

          local inspector = DisplayTableInspectorWindow(debugValues)
          inspector:SetDynamicUpdates(true)
        end
      )
    end
  end, { "ADDON_LOADED" }
)

module.isRetail = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
module.isClassic = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
module.isTBC = WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
module.isWOTLK = WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC

__module.Addon = module
