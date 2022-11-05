local Events = require("utility.manager-libraries.events")
local EventScheduler = require("utility.manager-libraries.event-scheduler")
local Logging = require("utility.helper-utils.logging-utils")
local BiomeTrees = require("utility.functions.biome-trees")
local SharedData = require("shared-data")
local RandomChance = require("utility.functions.random-chance")
local EntityUtils = require("utility.helper-utils.entity-utils")
local StringUtils = require("utility.helper-utils.string-utils")
local LoggingUtils = require("utility.helper-utils.logging-utils")
local Reincarnation = {}

---@class ReincarnationChanceEntry
---@field name string
---@field chance double # Normalised chance value.

---@class ReincarnationQueueEntry
---@field loggedTick uint
---@field surface LuaSurface
---@field position MapPosition
---@field type string
---@field orientation RealOrientation

---@class BiterWontBeRevived_Event
---@field name uint # The event Id.
---@field tick uint
---@field mod_name string # The mod that raised the event (`biter_revive`).
---@field entity LuaEntity
---@field unitNumber uint
---@field reviveType ReviveTypes
---@field entityName string|nil # Will be populated if obtained at time event is raised.
---@field force LuaForce|nil # Will be populated if obtained at time event is raised.
---@field forceIndex uint|nil # Will be populated if obtained at time event is raised.

---@class BiterRevivedFailed_Event
---@field name uint # The event Id.
---@field tick uint
---@field mod_name string # The mod that raised the event (`biter_revive`).
---@field unitNumber uint
---@field reviveType ReviveTypes
---@field prototypeName string
---@field surface LuaSurface
---@field position MapPosition
---@field orientation RealOrientation
---@field force LuaForce
---@field forceIndex uint

---@alias ReviveTypes "unit"|"turret"

-- How often the reincarnation queue is processed. These numbers must divide 60 cleanly.
---@type uint, uint
local QueueCyclesPerSecond, QueueCycleDelayTicks = 4, 15

---@enum ReincarnationType
local ReincarnationType = { tree = "tree", burningTree = "burningTree", rock = "rock", cliff = "cliff" }
---@enum MovableEntityTypes
local MovableEntityTypes = { unit = "unit", character = "character", car = "car", tank = "tank", ["spider-vehicle"] = "spider-vehicle" }

local DebugLogging = false

Reincarnation.OnLoad = function()
    script.on_nth_tick(QueueCycleDelayTicks, Reincarnation.ProcessReincarnationQueue)
    Events.RegisterHandlerEvent(defines.events.on_runtime_mod_setting_changed, "Reincarnation.UpdateSetting", Reincarnation.UpdateSetting)
    script.on_event(defines.events.on_surface_deleted, Reincarnation.OnSurfaceRemoved)
    script.on_event(defines.events.on_surface_cleared, Reincarnation.OnSurfaceRemoved)

    -- If Biter Revive mod is present listen to its unit died events, otherwise listen to main Factorio died events.
    if remote.interfaces["biter_revive"] ~= nil then
        local wontBeRevivedEventId = remote.call("biter_revive", "get_biter_wont_be_revived_event_id") --[[@as uint]]
        Events.RegisterHandlerEvent(wontBeRevivedEventId--[[@as defines.events]] , "Reincarnation.OnBiterWontBeRevived", Reincarnation.OnBiterWontBeRevived)
        local reviveFailedEventId = remote.call("biter_revive", "get_biter_revive_failed_event_id") --[[@as uint]]
        Events.RegisterHandlerEvent(reviveFailedEventId--[[@as defines.events]] , "Reincarnation.OnBiterReviveFailed", Reincarnation.OnBiterReviveFailed)
    else
        Events.RegisterHandlerEvent(defines.events.on_entity_died, "Reincarnation.OnEntityDiedUnit", Reincarnation.OnEntityDiedUnit, { { filter = "type", type = "unit" } })
    end
end

Reincarnation.OnStartup = function()
    BiomeTrees.OnStartup()
    Reincarnation.UpdateSetting(nil)

    -- Special to print any startup setting error messages after tick 0. Only needed if its tick 0 now.
    if game.tick == 0 then
        script.on_nth_tick(
            2,
            function(event)
                -- If its still tick 0 wait for later.
                if event.tick == 0 then
                    return
                end

                -- Print any errors and then remove them.
                for _, errorMessage in pairs(global.zeroTickErrors) do
                    LoggingUtils.LogPrintError(errorMessage)
                end
                global.zeroTickErrors = {}

                -- Deregister this event as never needed again.
                script.on_nth_tick(2, nil)
            end
        )
    end
end

Reincarnation.CreateGlobals = function()
    global.reincarnationChanceList = global.reincarnationChanceList or {} ---@type ReincarnationChanceEntry[]
    global.largeReincarnationsPush = global.largeReincarnationsPush or false ---@type boolean
    global.rawTreeOnDeathChance = global.rawTreeOnDeathChance or 0 ---@type double
    global.rawBurningTreeOnDeathChance = global.rawBurningTreeOnDeathChance or 0 ---@type double
    global.rawRockOnDeathChance = global.rawRockOnDeathChance or 0 ---@type double
    global.rawCliffOnDeathChance = global.rawCliffOnDeathChance or 0 ---@type double
    global.reincarnationQueue = global.reincarnationQueue or {} ---@type table<uint, ReincarnationQueueEntry> # The key is just a sequential Id.
    global.reincarnationQueueNextInsertIndex = global.reincarnationQueueNextInsertIndex or 0 ---@type uint # The Id for the next addition to the global.reincarnationQueue.
    global.reincarnationQueueProcessedPerStandardCycle = global.reincarnationQueueProcessedPerStandardCycle or 0 ---@type uint # The number of reincarnations to do per cycle on all but the first cycle each second. So is the whole number of the number of reincarnations per second divided by cycles per second.
    global.reincarnationQueueProcessedPerFirstCycle = global.reincarnationQueueProcessedPerFirstCycle or 0 ---@type uint # The number of reincarnations to do one cycle per second. Pickups up the left over reincarnations from the standard cycle count.
    global.reincarnationQueueProcessedCyclesThisSecond = global.reincarnationQueueProcessedCyclesThisSecond or 0 ---@type uint # Tracks how many cycles done this second so we know when to go back and use the process size of FirstCycle, rather than the rest of the cycles in the second which use the StandardCycle value.
    global.reincarnationsQueueMaxSize = global.reincarnationsQueueMaxSize or 0 ---@type uint # How many entries we can have in the queue before we start ignoring death events as they won't be processed before the max wait time is reached.
    global.reincarnationsQueueCurrentSize = global.reincarnationsQueueCurrentSize or 0 ---@type uint # The current number of reincarnations in the queue.
    global.maxTicksWaitForReincarnation = global.maxTicksWaitForReincarnation or 0 ---@type uint
    global.blacklistedPrototypeNames = global.blacklistedPrototypeNames or {} ---@type table<string, true> @ The key is blacklisted prototype name, with a value of true.
    global.raw_BlacklistedPrototypeNames = global.raw_BlacklistedPrototypeNames or "" ---@type string @ The last recorded raw setting value.
    global.blacklistedForceIds = global.blacklistedForceIds or {} ---@type table<uint, true> @ The force Id as key, with the force name we match against the setting on as the value.
    global.raw_BlacklistedForceNames = global.raw_BlacklistedForceNames or "" ---@type string @ The last recorded raw setting value.

    global.zeroTickErrors = global.zeroTickErrors or {} ---@type string[] @ Any errors raised during map startup (0 tick). They will be printed again on first non 0 tick cycle biter check cycle.
end

--- Called when a runtime setting is updated.
---@param event on_runtime_mod_setting_changed|nil
Reincarnation.UpdateSetting = function(event)
    local settingName
    if event ~= nil then
        settingName = event.setting
    end
    local settingErrorMessages = {} ---@type string[]
    local settingErrorMessage ---@type string

    if settingName == "biter_reincarnation-turn_to_tree_chance_percent" or settingName == nil then
        global.rawTreeOnDeathChance = tonumber(settings.global["biter_reincarnation-turn_to_tree_chance_percent"].value) / 100
    end

    if settingName == "biter_reincarnation-turn_to_burning_tree_chance_percent" or settingName == nil then
        global.rawBurningTreeOnDeathChance = tonumber(settings.global["biter_reincarnation-turn_to_burning_tree_chance_percent"].value) / 100
    end

    if settingName == "biter_reincarnation-turn_to_rock_chance_percent" or settingName == nil then
        global.rawRockOnDeathChance = tonumber(settings.global["biter_reincarnation-turn_to_rock_chance_percent"].value) / 100
    end

    if settingName == "biter_reincarnation-turn_to_cliff_chance_percent" or settingName == nil then
        global.rawCliffOnDeathChance = tonumber(settings.global["biter_reincarnation-turn_to_cliff_chance_percent"].value) / 100
    end

    if settingName == "biter_reincarnation-large_reincarnations_push" or settingName == nil then
        global.largeReincarnationsPush = settings.global["biter_reincarnation-large_reincarnations_push"].value
    end

    if settingName == "biter_reincarnation-max_reincarnations_per_second" or settingName == nil then
        local reincarnationsPerSecond = settings.global["biter_reincarnation-max_reincarnations_per_second"].value
        -- Catch left over from a number that doesn't divide cleanly by QueueCyclesPerSecond and add it to a special count for just that cycle that runs once per second.
        global.reincarnationQueueProcessedPerStandardCycle = math.floor(reincarnationsPerSecond / QueueCyclesPerSecond)
        global.reincarnationQueueProcessedPerFirstCycle = (reincarnationsPerSecond % (QueueCyclesPerSecond * global.reincarnationQueueProcessedPerStandardCycle)) + global.reincarnationQueueProcessedPerStandardCycle
    end

    if settingName == "biter_reincarnation-max_seconds_wait_for_reincarnation" or settingName == nil then
        global.maxTicksWaitForReincarnation = settings.global["biter_reincarnation-max_seconds_wait_for_reincarnation"].value * 60
    end

    if settingName == "biter_reincarnation-max_reincarnations_per_second" or settingName == "biter_reincarnation-max_seconds_wait_for_reincarnation" or settingName == nil then
        -- If this gets increased or decreased we just leave the death recording and queue processing functions to catch up to the new value. Nothing needs to be proactively done at this stage.
        global.reincarnationsQueueMaxSize = settings.global["biter_reincarnation-max_reincarnations_per_second"].value * settings.global["biter_reincarnation-max_seconds_wait_for_reincarnation"].value --[[@as uint]]
    end

    global.reincarnationChanceList = {
        { name = ReincarnationType.tree, chance = global.rawTreeOnDeathChance },
        { name = ReincarnationType.burningTree, chance = global.rawBurningTreeOnDeathChance },
        { name = ReincarnationType.rock, chance = global.rawRockOnDeathChance },
        { name = ReincarnationType.cliff, chance = global.rawCliffOnDeathChance }
    }
    RandomChance.NormaliseChanceList(global.reincarnationChanceList, "chance", true)

    if event == nil or event.setting == "biter_reincarnation-blacklisted_prototype_names" then
        local settingValue = settings.global["biter_reincarnation-blacklisted_prototype_names"].value --[[@as string]]

        -- Check if the setting has changed before we bother to process it.
        local changed = settingValue ~= global.raw_BlacklistedPrototypeNames
        global.raw_BlacklistedPrototypeNames = settingValue

        -- Only check and update if the setting value was actually changed from before.
        if changed then
            global.blacklistedPrototypeNames = StringUtils.SplitStringOnCharactersToDictionary(settingValue, ",")

            -- Check each prototype name is valid and tell the player about any that aren't. Don't block the update though as it does no harm.
            local count = 1
            for name in pairs(global.blacklistedPrototypeNames) do
                local prototype = game.entity_prototypes[name]
                if prototype == nil then
                    settingErrorMessage = "Biter Reincarnation - unrecognised prototype name `" .. name .. "` in blacklisted prototype names."
                    LoggingUtils.LogPrintError(settingErrorMessage)
                    settingErrorMessages[#settingErrorMessages + 1] = settingErrorMessage
                elseif prototype.type ~= "unit" then
                    settingErrorMessage = "Biter Reincarnation - prototype name `" .. name .. "` in blacklisted prototype names isn't of type `unit` and so could never be reincarnated anyways."
                    LoggingUtils.LogPrintError(settingErrorMessage)
                    settingErrorMessages[#settingErrorMessages + 1] = settingErrorMessage
                end
                count = count + 1
            end
        end
    end
    if event == nil or event.setting == "biter_reincarnation-blacklisted_force_names" then
        local settingValue = settings.global["biter_reincarnation-blacklisted_force_names"].value --[[@as string]]

        -- Check if the setting has changed before we bother to process it.
        local changed = settingValue ~= global.raw_BlacklistedForceNames
        global.raw_BlacklistedForceNames = settingValue

        -- Only check and update if the setting value was actually changed from before.
        if changed then
            local forceNames = StringUtils.SplitStringOnCharactersToDictionary(settingValue, ",")

            -- Blank the global before adding the new ones every time.
            global.blacklistedForceIds = {}

            -- Only add valid force Id's to the global.
            for forceName in pairs(forceNames) do
                local force = game.forces[forceName] --[[@as LuaForce]]
                if force ~= nil then
                    global.blacklistedForceIds[force.index] = true
                else
                    settingErrorMessage = "Biter Reincarnation - Invalid force name provided: " .. forceName
                    LoggingUtils.LogPrintError(settingErrorMessage)
                    settingErrorMessages[#settingErrorMessages + 1] = settingErrorMessage
                end
            end
        end
    end

    -- If its 0 tick (initial map start and there were errors add them to be written out after a few ticks)
    if game.tick == 0 and #settingErrorMessages > 0 then
        global.zeroTickErrors = settingErrorMessages
    end
end

--- Process the reincarnation queue.
---@param event UtilityScheduledEvent_CallbackObject
Reincarnation.ProcessReincarnationQueue = function(event)
    -- If there's nothing to be done, we don';'t need to do any preparation work.
    if global.reincarnationsQueueCurrentSize == 0 then return end

    local doneThisCycle = 0

    -- Work out how many tasks can be done this cycle. Complexity makes sure we do the right number of reincarnations spread over each second.
    local tasksThisCycle
    global.reincarnationQueueProcessedCyclesThisSecond = global.reincarnationQueueProcessedCyclesThisSecond + 1
    if global.reincarnationQueueProcessedCyclesThisSecond == 1 then
        tasksThisCycle = global.reincarnationQueueProcessedPerFirstCycle
    else
        tasksThisCycle = global.reincarnationQueueProcessedPerStandardCycle
    end
    if global.reincarnationQueueProcessedCyclesThisSecond == QueueCyclesPerSecond then
        global.reincarnationQueueProcessedCyclesThisSecond = 0
    end

    for k, details in pairs(global.reincarnationQueue) do
        -- Remove the entry from the queue first thing. As we might quit the loop mid processing.
        global.reincarnationQueue[k] = nil

        -- Do the reincarnation.
        local surface, targetPosition, type, orientation = details.surface, details.position, details.type, details.orientation
        if type == ReincarnationType.tree then
            BiomeTrees.AddBiomeTreeNearPosition(surface, targetPosition, 2)
        elseif type == ReincarnationType.burningTree then
            local _, treePosition = BiomeTrees.AddBiomeTreeNearPosition(surface, targetPosition, 2)
            if treePosition ~= nil then
                Reincarnation.AddTreeFireToPosition(surface, treePosition)
            end
        elseif type == ReincarnationType.rock then
            Reincarnation.AddRockNearPosition(surface, targetPosition)
        elseif type == ReincarnationType.cliff then
            Reincarnation.AddCliffNearPosition(surface, targetPosition, orientation)
        else
            error("unsupported type: " .. type)
        end
        doneThisCycle = doneThisCycle + 1

        -- Check if we have completed all the reincarnations we need to do
        if doneThisCycle >= tasksThisCycle then
            break
        end
    end

    global.reincarnationsQueueCurrentSize = global.reincarnationsQueueCurrentSize - doneThisCycle
end

--- Called when a unit type entity died and the Biter Revive mod isn't present.
---@param event on_entity_died
Reincarnation.OnEntityDiedUnit = function(event)

    -- Check we aren't over our queue limit.
    if global.reincarnationsQueueCurrentSize > global.reincarnationsQueueMaxSize then
        return
    end

    Reincarnation.CheckAndAddDeadEntityToReincarnationQueue(event.entity, event.tick)
end

--- Record a valid entity to the reincarnation queue if it happens to win the chance lottery.
---@param entity LuaEntity
---@param currentTick uint
---@param entity_name string|nil # If known can provide, otherwise obtained from entity.
---@param entity_force LuaForce|nil # If known can provide, otherwise obtained from entity.
---@param entity_force_index uint|nil # If known can provide, otherwise obtained from entity.
Reincarnation.CheckAndAddDeadEntityToReincarnationQueue = function(entity, currentTick, entity_name, entity_force, entity_force_index)
    entity_name = entity_name or entity.name
    -- Check if the prototype name is blacklisted.
    if global.blacklistedPrototypeNames[entity_name] ~= nil then
        return
    end

    entity_force = entity_force or entity.force --[[@as LuaForce]]
    entity_force_index = entity_force_index or entity_force.index
    -- Check if the force is blacklisted.
    if global.blacklistedForceIds[entity_force_index] ~= nil then
        return
    end

    local selectedReincarnationType = RandomChance.GetRandomEntryFromNormalisedDataSet(global.reincarnationChanceList, "chance")
    if selectedReincarnationType == nil then
        return
    end
    ---@type ReincarnationQueueEntry
    local details = {
        loggedTick = currentTick,
        surface = entity.surface,
        position = entity.position,
        type = selectedReincarnationType.name,
        orientation = entity.orientation
    }
    global.reincarnationQueueNextInsertIndex = global.reincarnationQueueNextInsertIndex + 1
    global.reincarnationQueue[global.reincarnationQueueNextInsertIndex--[[@as uint]] ] = details
    global.reincarnationsQueueCurrentSize = global.reincarnationsQueueCurrentSize + 1
end

--- Called when the Biter Revive mod raises this custom event. This is when the entity has first died and its been decided it won't try to be revived in the future.
---@param event BiterWontBeRevived_Event
Reincarnation.OnBiterWontBeRevived = function(event)
    if event.reviveType ~= "unit" then return end

    -- Check we aren't over our queue limit.
    if global.reincarnationsQueueCurrentSize > global.reincarnationsQueueMaxSize then
        return
    end

    Reincarnation.CheckAndAddDeadEntityToReincarnationQueue(event.entity, event.tick, event.entityName, event.force, event.forceIndex)
end

--- Called when the Biter Revive mod raises this custom event. This is when the entity has first died and its been decided it won't try to be revived in the future.
---@param event BiterRevivedFailed_Event
Reincarnation.OnBiterReviveFailed = function(event)
    if event.reviveType ~= "unit" then return end

    -- Check we aren't over our queue limit.
    if global.reincarnationsQueueCurrentSize > global.reincarnationsQueueMaxSize then
        return
    end

    -- Check if the prototype name is blacklisted.
    if global.blacklistedPrototypeNames[event.prototypeName] ~= nil then
        return
    end

    -- Check if the force is blacklisted.
    if global.blacklistedForceIds[event.forceIndex] ~= nil then
        return
    end

    local selectedReincarnationType = RandomChance.GetRandomEntryFromNormalisedDataSet(global.reincarnationChanceList, "chance")
    if selectedReincarnationType == nil then
        return
    end
    ---@type ReincarnationQueueEntry
    local details = {
        loggedTick = event.tick,
        surface = event.surface,
        position = event.position,
        type = selectedReincarnationType.name,
        orientation = event.orientation
    }
    global.reincarnationQueueNextInsertIndex = global.reincarnationQueueNextInsertIndex + 1
    global.reincarnationQueue[global.reincarnationQueueNextInsertIndex--[[@as uint]] ] = details
    global.reincarnationsQueueCurrentSize = global.reincarnationsQueueCurrentSize + 1
end

--- Add a fire for a tree at a given position.
---@param surface LuaSurface
---@param targetPosition MapPosition
Reincarnation.AddTreeFireToPosition = function(surface, targetPosition)
    -- Make 2 lots of fire to ensure the tree catches fire
    surface.create_entity { name = "fire-flame-on-tree", position = targetPosition, raise_built = true }
    surface.create_entity { name = "fire-flame-on-tree", position = targetPosition, raise_built = true }
end

--- Add a rock near a position.
---@param surface LuaSurface
---@param targetPosition MapPosition
Reincarnation.AddRockNearPosition = function(surface, targetPosition)
    local typeData = RandomChance.GetRandomEntryFromNormalisedDataSet(SharedData.RockTypes, "chance")

    local newPosition = surface.find_non_colliding_position(typeData.name, targetPosition, 2, 0.2)
    local displaceRequired = false
    if newPosition == nil then
        newPosition = surface.find_non_colliding_position(typeData.placementName, targetPosition, 2, 0.2)
        displaceRequired = true
    end
    if newPosition == nil then
        if DebugLogging then Logging.ModLog("No position for new rock found", true) end
        return
    end

    local rockEntity = surface.create_entity { name = typeData.name, position = newPosition, force = "neutral", raise_built = true }
    if rockEntity == nil then
        Logging.LogPrintWarning("Failed to create rock at found position")
        return
    end

    if displaceRequired then
        Reincarnation.DisplaceEntitiesInBoundingBox(surface, rockEntity)
    end
end

--- Move any teleportable entities in the bounding box of an entity out of the way. Anything non movable is just killed.
---@param surface LuaSurface
---@param createdEntity LuaEntity
Reincarnation.DisplaceEntitiesInBoundingBox = function(surface, createdEntity)
    for _, entity in pairs(EntityUtils.ReturnAllObjectsInArea(surface, createdEntity.bounding_box, true, nil, true, true, { createdEntity })) do
        if global.largeReincarnationsPush then
            local entityMoved = false
            if MovableEntityTypes[entity.type] ~= nil then
                local entityNewPosition = surface.find_non_colliding_position(entity.name, entity.position, 2, 0.1)
                if entityNewPosition ~= nil then
                    entity.teleport(entityNewPosition)
                    entityMoved = true
                end
            end
            if not entityMoved then
                entity.die("neutral", createdEntity)
            end
        else
            entity.die("neutral", createdEntity)
        end
    end
end

--- Add cliffs near the target position.
---@param surface LuaSurface
---@param targetPosition MapPosition
---@param orientation double
Reincarnation.AddCliffNearPosition = function(surface, targetPosition, orientation)
    local cliffPositionCenter = {
        x = (math.floor(targetPosition.x / 4) * 4) + 2,
        y = (math.floor(targetPosition.y / 4) * 4) + 2.5
    }

    local cliffPositionLeft, cliffPositionRight, generalFacing, cliffTypeLeft, cliffTypeRight
    if orientation >= 0.875 or orientation < 0.125 then
        -- Biter heading north-ish
        generalFacing = "north-south"
        cliffTypeLeft = "none-to-west"
        cliffTypeRight = "east-to-none"
    elseif orientation >= 0.125 and orientation < 0.375 then
        -- Biter heading east-ish
        generalFacing = "east-west"
        cliffTypeLeft = "none-to-north"
        cliffTypeRight = "none-to-west"
    elseif orientation >= 0.375 and orientation < 0.625 then
        -- Biter heading south-ish
        generalFacing = "north-south"
        cliffTypeLeft = "west-to-none"
        cliffTypeRight = "none-to-east"
    elseif orientation >= 0.625 and orientation < 0.875 then
        -- Biter heading west-ish
        generalFacing = "east-west"
        cliffTypeLeft = "north-to-none"
        cliffTypeRight = "east-to-none"
    end
    if generalFacing == "north-south" then
        if cliffPositionCenter.x - targetPosition.x < 0 then
            cliffPositionRight = cliffPositionCenter
            cliffPositionLeft = { x = cliffPositionCenter.x + 4, y = cliffPositionCenter.y }
        else
            cliffPositionLeft = cliffPositionCenter
            cliffPositionRight = { x = cliffPositionCenter.x - 4, y = cliffPositionCenter.y }
        end
        if cliffPositionCenter.y - targetPosition.y < -2 then
            cliffPositionRight.y = cliffPositionRight.y + 4
            cliffPositionLeft.y = cliffPositionLeft.y + 4
        end
    elseif generalFacing == "east-west" then
        if cliffPositionCenter.y - targetPosition.y < 0 then
            cliffPositionRight = cliffPositionCenter
            cliffPositionLeft = { y = cliffPositionCenter.y + 4, x = cliffPositionCenter.x }
        else
            cliffPositionLeft = cliffPositionCenter
            cliffPositionRight = { y = cliffPositionCenter.y - 4, x = cliffPositionCenter.x }
        end
        if cliffPositionCenter.x - targetPosition.x < -2 then
            cliffPositionRight.x = cliffPositionRight.x + 4
            cliffPositionLeft.x = cliffPositionLeft.x + 4
        end
    end

    local cliffEntityLeft = surface.create_entity { name = "cliff", position = cliffPositionLeft, force = "neutral", cliff_orientation = cliffTypeLeft, raise_built = true }
    local cliffEntityRight = surface.create_entity { name = "cliff", position = cliffPositionRight, force = "neutral", cliff_orientation = cliffTypeRight, raise_built = true }

    if cliffEntityLeft == nil or cliffEntityRight == nil then
        -- One of the cliffs isn't good so remove both silently.
        if cliffEntityLeft ~= nil then
            cliffEntityLeft.destroy({ do_cliff_correction = false, raise_destroy = false })
            cliffEntityLeft = nil
        end
        if cliffEntityRight ~= nil then
            cliffEntityRight.destroy({ do_cliff_correction = false, raise_destroy = false })
            cliffEntityRight = nil
        end

        if DebugLogging then Logging.ModLog("Cliffs failed to create so removed.", true) end

        -- Don't try to do anything further with the cliffs as it didn't create right.
        return
    end

    Reincarnation.DisplaceEntitiesInBoundingBox(surface, cliffEntityLeft)
    Reincarnation.DisplaceEntitiesInBoundingBox(surface, cliffEntityRight)
end

--- Called when a surface is removed or cleared and we need to remove any scheduled reincarnations on that surface and other cached data.
---@param event on_surface_cleared|on_surface_deleted
Reincarnation.OnSurfaceRemoved = function(event)
    -- Just empty the reincarnationQueue of any entries for that surface.
    for i, reincarnationDetails in pairs(global.reincarnationQueue) do
        if not reincarnationDetails.surface.valid or reincarnationDetails.surface.index == event.surface_index then
            global.reincarnationQueue[i] = nil
            global.reincarnationsQueueCurrentSize = global.reincarnationsQueueCurrentSize - 1
        end
    end
end

return Reincarnation
