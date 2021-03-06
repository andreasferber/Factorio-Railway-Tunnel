local EventScheduler = require("utility/event-scheduler")
local TrainManager = {}
local Interfaces = require("utility/interfaces")
local Events = require("utility/events")
local Utils = require("utility/utils")
local TunnelCommon = require("scripts/common/tunnel-common")

TrainManager.CreateGlobals = function()
    global.trainManager = global.trainManager or {}
    global.trainManager.managedTrains = global.trainManager.managedTrains or {} --[[
        id = uniqiue id of this managed train passing through the tunnel.
        aboveTrainEntering = LuaTrain of the entering train on the world surface.
        aboveTrainEnteringId = The LuaTrain ID of the above Train Entering.
        aboveTrainEnteringSpeedSign = The sign of the speed value for the entering train.
        aboveTrainLeaving = LuaTrain of the train created leaving the tunnel on the world surface.
        aboveTrainLeavingId = The LuaTrain ID of the above Train Leaving.
        aboveTrainLeavingSpeedSign = The sign of the speed value for the leaving train.
        trainTravelDirection = defines.direction the train is heading in.
        trainTravelOrientation = the orientation of the trainTravelDirection.
        trainTravellingForwards = boolean if the train is moving forwards or backwards from its viewpoint.
        surfaceEntrancePortal = the portal global object of the entrance portal for this tunnel usage instance.
        surfaceEntrancePortalEndSignal = the endSignal global object of the rail signal at the end of the entrance portal track (forced closed signal).
        surfaceExitPortal = the portal global object of the exit portal for this tunnel usage instance.
        surfaceExitPortalEndSignal = the endSignal global object of the rail signal at the end of the exit portal track (forced closed signal).
        tunnel = ref to the global tunnel object.
        origTrainSchedule = copy of the origional train schedule table made when triggered the managed train process.
        undergroundTrain = LuaTrain of the train created in the underground surface.
        undergroundTrainSpeedSign = The sign of the speed value for the underground train.
        undergroundLeavingEntrySignalPosition = The underground position equivilent to the entry signal that the underground train starts leaving when it approaches.
        aboveSurface = LuaSurface of the main world surface.
        undergroundSurface = LuaSurface of the specific underground surface.
        aboveTrainLeavingCarriagesPlaced = count of how many carriages placed so far in the above train while its leaving.
        aboveLeavingSignalPosition = The above ground position that the rear leaving carriage should trigger the next carriage at.
        undergroundLeavingExitSignalPosition = The underground position that the current underground carriage should trigger the creation of tha above carriage at.
        speed = The current speed of the train going through the tunnel.
        speedLastUpdateTick = The last tick when the speed was updated.
    ]]
    global.trainManager.enteringTrainIdToManagedTrain = global.trainManager.enteringTrainIdToManagedTrain or {}
    global.trainManager.leavingTrainIdToManagedTrain = global.trainManager.leavingTrainIdToManagedTrain or {}
end

TrainManager.OnLoad = function()
    Interfaces.RegisterInterface("TrainManager.TrainEnteringInitial", TrainManager.TrainEnteringInitial)
    EventScheduler.RegisterScheduledEventType("TrainManager.TrainEnteringOngoing", TrainManager.TrainEnteringOngoing)
    EventScheduler.RegisterScheduledEventType("TrainManager.TrainUndergroundOngoing", TrainManager.TrainUndergroundOngoing)
    EventScheduler.RegisterScheduledEventType("TrainManager.TrainLeavingOngoing", TrainManager.TrainLeavingOngoing)
    Events.RegisterHandlerEvent(defines.events.on_train_created, "TrainManager.TrainEnteringOngoing_OnTrainCreated", TrainManager.TrainEnteringOngoing_OnTrainCreated)
    Events.RegisterHandlerEvent(defines.events.on_train_created, "TrainManager.TrainLeavingOngoing_OnTrainCreated", TrainManager.TrainLeavingOngoing_OnTrainCreated)
    Interfaces.RegisterInterface("TrainManager.IsTunnelInUse", TrainManager.IsTunnelInUse)
    Interfaces.RegisterInterface("TrainManager.TunnelRemoved", TrainManager.TunnelRemoved)
end

TrainManager.TrainEnteringInitial = function(trainEntering, surfaceEntrancePortalEndSignal)
    local trainManagerId = #global.trainManager.managedTrains + 1
    global.trainManager.managedTrains[trainManagerId] = {
        id = trainManagerId,
        aboveTrainEntering = trainEntering,
        aboveTrainEnteringId = trainEntering.id,
        aboveTrainEnteringSpeedSign = 0,
        surfaceEntrancePortalEndSignal = surfaceEntrancePortalEndSignal,
        surfaceEntrancePortal = surfaceEntrancePortalEndSignal.portal,
        tunnel = surfaceEntrancePortalEndSignal.portal.tunnel,
        origTrainSchedule = Utils.DeepCopy(trainEntering.schedule),
        origTrainScheduleStopEntity = trainEntering.path_end_stop,
        trainTravelDirection = Utils.LoopDirectionValue(surfaceEntrancePortalEndSignal.entity.direction + 4)
    }
    local trainManagerEntry = global.trainManager.managedTrains[trainManagerId]
    local tunnel = trainManagerEntry.tunnel
    trainManagerEntry.aboveSurface = tunnel.aboveSurface
    trainManagerEntry.undergroundSurface = tunnel.undergroundSurface
    if trainManagerEntry.aboveTrainEntering.speed > 0 then
        trainManagerEntry.trainTravellingForwards = true
        trainManagerEntry.aboveTrainEnteringSpeedSign = 1
    else
        trainManagerEntry.trainTravellingForwards = false
        trainManagerEntry.aboveTrainEnteringSpeedSign = -1
    end
    trainManagerEntry.speed = math.abs(trainManagerEntry.aboveTrainEntering.speed)
    trainManagerEntry.speedLastUpdateTick = game.tick
    trainManagerEntry.trainTravelOrientation = trainManagerEntry.trainTravelDirection / 8
    global.trainManager.enteringTrainIdToManagedTrain[trainEntering.id] = trainManagerEntry

    -- Get the exit end signal on the other portal so we know when to bring the train back in.
    for _, portal in pairs(tunnel.portals) do
        if portal.id ~= surfaceEntrancePortalEndSignal.portal.id then
            for _, endSignal in pairs(portal.endSignals) do
                if endSignal.entity.direction ~= surfaceEntrancePortalEndSignal.entity.direction then
                    trainManagerEntry.surfaceExitPortalEndSignal = endSignal
                    trainManagerEntry.surfaceExitPortal = endSignal.portal
                    break
                end
            end
            break
        end
    end

    -- Copy the above train underground and set it running.
    local sourceTrain = trainManagerEntry.aboveTrainEntering
    local undergroundTrain = TrainManager.CopyTrainToUnderground(trainManagerEntry)

    --Set the speed and correct if after setting the schedule if needed. Easier than trying to work out what way the trains are facing to each other.
    undergroundTrain.speed = trainManagerEntry.speed
    local undergroundTrainEndScheduleTargetPos =
        Utils.ApplyOffsetToPosition(
        Utils.RotatePositionAround0(
            tunnel.alignmentOrientation,
            {
                x = tunnel.undergroundModifiers.tunnelInstanceValue + 1,
                y = 0
            }
        ),
        Utils.RotatePositionAround0(
            trainManagerEntry.trainTravelOrientation,
            {
                x = 0,
                y = 0 - (TunnelCommon.setupValues.undergroundLeadInTiles - 1)
            }
        )
    )
    undergroundTrain.schedule = {
        current = 1,
        records = {
            {
                rail = tunnel.undergroundSurface.find_entity("straight-rail", undergroundTrainEndScheduleTargetPos)
            }
        }
    }
    undergroundTrain.manual_mode = false
    trainManagerEntry.undergroundTrainSpeedSign = 1
    if undergroundTrain.speed == 0 then
        undergroundTrain.speed = -1*trainManagerEntry.speed
        trainManagerEntry.undergroundTrainSpeedSign = -1
    end
    trainManagerEntry.undergroundTrain = undergroundTrain

    trainManagerEntry.undergroundLeavingEntrySignalPosition = Utils.ApplyOffsetToPosition(trainManagerEntry.surfaceExitPortal.entrySignals["out"].entity.position, trainManagerEntry.tunnel.undergroundModifiers.undergroundOffsetFromSurface)

    EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainEnteringOngoing", trainManagerId)
    EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainUndergroundOngoing", trainManagerId)
end

TrainManager.TrainEnteringOngoing = function(event)
    local trainManagerEntry = global.trainManager.managedTrains[event.instanceId]
    --Need to create a dummy leaving train at this point to reserve the train limit.
    TrainManager.RefreshTrainSpeed(trainManagerEntry)
    trainManagerEntry.aboveTrainEntering.manual_mode = true
    local nextStockAttributeName = "front_stock"
    if trainManagerEntry.aboveTrainEnteringSpeedSign < 0 then
        nextStockAttributeName = "back_stock"
    end
    trainManagerEntry.aboveTrainEntering.speed = trainManagerEntry.aboveTrainEnteringSpeedSign * trainManagerEntry.speed

    if Utils.GetDistance(trainManagerEntry.aboveTrainEntering[nextStockAttributeName].position, trainManagerEntry.surfaceEntrancePortalEndSignal.entity.position) < 10 then
        trainManagerEntry.aboveTrainEntering[nextStockAttributeName].destroy()
    end
    if trainManagerEntry.aboveTrainEntering ~= nil and trainManagerEntry.aboveTrainEntering.valid and #trainManagerEntry.aboveTrainEntering[nextStockAttributeName] ~= nil then
        EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainEnteringOngoing", trainManagerEntry.id)
    else
        global.trainManager.enteringTrainIdToManagedTrain[trainManagerEntry.aboveTrainEnteringId] = nil
        trainManagerEntry.aboveTrainEntering = nil
        trainManagerEntry.aboveTrainEnteringId = nil
    end
end

TrainManager.TrainUndergroundOngoing = function(event)
    local trainManagerEntry = global.trainManager.managedTrains[event.instanceId]
    local nextStockAttributeName = "front_stock"
    if trainManagerEntry.undergroundTrainSpeedSign < 0 then
        nextStockAttributeName = "back_stock"
    end
    -- TODO: this isn't perfect, but pretty good and supports orientations.
    if Utils.GetDistance(trainManagerEntry.undergroundTrain[nextStockAttributeName].position, trainManagerEntry.undergroundLeavingEntrySignalPosition) > 35 then
        EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainUndergroundOngoing", trainManagerEntry.id)
    else
        TrainManager.TrainLeavingInitial(trainManagerEntry)
    end
end

TrainManager.TrainLeavingInitial = function(trainManagerEntry)
    TrainManager.RefreshTrainSpeed(trainManagerEntry)
    local sourceTrain, nextStockAttributeName = trainManagerEntry.undergroundTrain
    if trainManagerEntry.undergroundTrainSpeedSign > 0 then
        nextStockAttributeName = "front_stock"
    else
        nextStockAttributeName = "back_stock"
    end

    local refCarriage = sourceTrain[nextStockAttributeName]
    local placementPosition = Utils.ApplyOffsetToPosition(refCarriage.position, trainManagerEntry.tunnel.undergroundModifiers.surfaceOffsetFromUnderground)
    local placedCarriage = refCarriage.clone {position = placementPosition, surface = trainManagerEntry.aboveSurface}
    trainManagerEntry.aboveTrainLeavingCarriagesPlaced = 1

    local aboveTrainLeaving = placedCarriage.train
    trainManagerEntry.aboveTrainLeaving, trainManagerEntry.aboveTrainLeavingId = aboveTrainLeaving, aboveTrainLeaving.id
    global.trainManager.leavingTrainIdToManagedTrain[aboveTrainLeaving.id] = trainManagerEntry
    aboveTrainLeaving.schedule = trainManagerEntry.origTrainSchedule
    aboveTrainLeaving.manual_mode = false
    if placedCarriage.orientation == refCarriage.orientation then
        -- As theres only 1 placed carriage we can set the speed based on the refCarriage. New train will have a direciton that matches the single placed carriage.
        trainManagerEntry.aboveTrainLeavingSpeedSign = 1
    else
        trainManagerEntry.aboveTrainLeavingSpeedSign = -1
    end
    aboveTrainLeaving.speed = trainManagerEntry.aboveTrainLeavingSpeedSign * trainManagerEntry.speed
    if trainManagerEntry.origTrainScheduleStopEntity.trains_limit ~= Utils.MaxTrainStopLimit then
        trainManagerEntry.origTrainScheduleStopEntity.trains_limit = trainManagerEntry.origTrainScheduleStopEntity.trains_limit + 1
        aboveTrainLeaving.recalculate_path()
        trainManagerEntry.origTrainScheduleStopEntity.trains_limit = trainManagerEntry.origTrainScheduleStopEntity.trains_limit - 1
    else
        aboveTrainLeaving.recalculate_path()
    end

    trainManagerEntry.undergroundLeavingExitSignalPosition = Utils.ApplyOffsetToPosition(trainManagerEntry.surfaceExitPortalEndSignal.entity.position, trainManagerEntry.tunnel.undergroundModifiers.undergroundOffsetFromSurface)
    EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainLeavingOngoing", trainManagerEntry.id)
end

TrainManager.TrainLeavingOngoing = function(event)
    local trainManagerEntry = global.trainManager.managedTrains[event.instanceId]
    TrainManager.RefreshTrainSpeed(trainManagerEntry)
    local aboveTrainLeaving, sourceTrain = trainManagerEntry.aboveTrainLeaving, trainManagerEntry.undergroundTrain

    local currentSourceTrainCarriageIndex = trainManagerEntry.aboveTrainLeavingCarriagesPlaced
    local nextSourceTrainCarriageIndex = currentSourceTrainCarriageIndex + 1
    if trainManagerEntry.undergroundTrainSpeedSign < 0 then
        currentSourceTrainCarriageIndex = #sourceTrain.carriages - trainManagerEntry.aboveTrainLeavingCarriagesPlaced
        nextSourceTrainCarriageIndex = currentSourceTrainCarriageIndex
    end

    local currentSourceCarriageEntity, nextSourceCarriageEntity = sourceTrain.carriages[currentSourceTrainCarriageIndex], sourceTrain.carriages[nextSourceTrainCarriageIndex]
    if nextSourceCarriageEntity == nil then
        -- All wagons placed so tidy up
        TrainManager.TrainLeavingCompleted(trainManagerEntry)
        return
    end

    -- TODO: this isn't perfect, but pretty good and supports orientations.
    if Utils.GetDistance(currentSourceCarriageEntity.position, trainManagerEntry.undergroundLeavingExitSignalPosition) > 10 then
        local nextCarriagePosition = Utils.ApplyOffsetToPosition(nextSourceCarriageEntity.position, trainManagerEntry.tunnel.undergroundModifiers.surfaceOffsetFromUnderground)
        nextSourceCarriageEntity.clone {position = nextCarriagePosition, surface = trainManagerEntry.aboveSurface}
        trainManagerEntry.aboveTrainLeavingCarriagesPlaced = trainManagerEntry.aboveTrainLeavingCarriagesPlaced + 1
        aboveTrainLeaving = trainManagerEntry.aboveTrainLeaving -- LuaTrain has been replaced and updated by adding a wagon, so obtain a local reference to it again.
    end

    aboveTrainLeaving.speed = trainManagerEntry.aboveTrainLeavingSpeedSign * trainManagerEntry.speed
    if aboveTrainLeaving.state == defines.train_state.on_the_path then
        sourceTrain.manual_mode = false
    else
        sourceTrain.manual_mode = true
    end
    sourceTrain.speed = trainManagerEntry.undergroundTrainSpeedSign * trainManagerEntry.speed

    aboveTrainLeaving.schedule = trainManagerEntry.origTrainSchedule
    aboveTrainLeaving.manual_mode = false
    if trainManagerEntry.origTrainScheduleStopEntity.trains_limit ~= Utils.MaxTrainStopLimit then
        trainManagerEntry.origTrainScheduleStopEntity.trains_limit = trainManagerEntry.origTrainScheduleStopEntity.trains_limit + 1
        aboveTrainLeaving.recalculate_path()
        trainManagerEntry.origTrainScheduleStopEntity.trains_limit = trainManagerEntry.origTrainScheduleStopEntity.trains_limit - 1
    else
        aboveTrainLeaving.recalculate_path()
    end

    EventScheduler.ScheduleEvent(game.tick + 1, "TrainManager.TrainLeavingOngoing", trainManagerEntry.id)
end

TrainManager.TrainLeavingCompleted = function(trainManagerEntry)
    trainManagerEntry.aboveTrainLeaving.schedule = trainManagerEntry.origTrainSchedule
    trainManagerEntry.aboveTrainLeaving.manual_mode = false
    trainManagerEntry.aboveTrainLeaving.speed = trainManagerEntry.aboveTrainLeavingSpeedSign * trainManagerEntry.speed

    for _, carriage in pairs(trainManagerEntry.undergroundTrain.carriages) do
        carriage.destroy()
    end
    trainManagerEntry.undergroundTrain = nil

    global.trainManager.leavingTrainIdToManagedTrain[trainManagerEntry.aboveTrainLeaving.id] = nil
    global.trainManager.managedTrains[trainManagerEntry.id] = nil
end

TrainManager.TrainEnteringOngoing_OnTrainCreated = function(event)
    if event.old_train_id_1 == nil then
        return
    end
    local managedTrain = global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_1] or global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_2]
    if managedTrain == nil then
        return
    end
    managedTrain.aboveTrainEntering = event.train
    managedTrain.aboveTrainEnteringId = event.train.id
    if global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_1] ~= nil then
        global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_1] = nil
    end
    if global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_2] ~= nil then
        global.trainManager.enteringTrainIdToManagedTrain[event.old_train_id_2] = nil
    end
    global.trainManager.enteringTrainIdToManagedTrain[event.train.id] = managedTrain
end

TrainManager.TrainLeavingOngoing_OnTrainCreated = function(event)
    if event.old_train_id_1 == nil then
        return
    end
    local managedTrain = global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_1] or global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_2]
    if managedTrain == nil then
        return
    end
    managedTrain.aboveTrainLeaving = event.train
    managedTrain.aboveTrainLeavingId = event.train.id
    if global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_1] ~= nil then
        global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_1] = nil
    end
    if global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_2] ~= nil then
        global.trainManager.leavingTrainIdToManagedTrain[event.old_train_id_2] = nil
    end
    global.trainManager.leavingTrainIdToManagedTrain[event.train.id] = managedTrain
end

TrainManager.RefreshTrainSpeed = function(trainManagerEntry)
    -- LuaTrain speeds might be invalidated by the actions taken in the
    -- various event handlers, therefore make sure to only recalculate
    -- once per tick
    if trainManagerEntry.speedLastUpdateTick == game.tick then
        return
    end

    -- refresh speed signs, as they might change when train compositions
    -- change
    -- note that the signs are deliberately left untouched if speed is 0
    if trainManagerEntry.aboveTrainEntering and trainManagerEntry.aboveTrainEntering.valid then
        if trainManagerEntry.aboveTrainEntering.speed > 0 then
            trainManagerEntry.aboveTrainEnteringSpeedSign = 1
        elseif trainManagerEntry.aboveTrainEntering.speed < 0 then
            trainManagerEntry.aboveTrainEnteringSpeedSign = -1
        end
    end

    if trainManagerEntry.undergroundTrain and trainManagerEntry.undergroundTrain.valid then
        if trainManagerEntry.undergroundTrain.speed > 0 then
            trainManagerEntry.undergroundTrainSpeedSign = 1
        elseif trainManagerEntry.undergroundTrain.speed < 0 then
            trainManagerEntry.undergroundTrainSpeedSign = -1
        end
    end

    if trainManagerEntry.aboveTrainLeaving and trainManagerEntry.aboveTrainLeaving.valid then
        if trainManagerEntry.aboveTrainLeaving.speed > 0 then
            trainManagerEntry.aboveTrainLeavingSpeedSign = 1
        elseif trainManagerEntry.aboveTrainLeaving.speed < 0 then
            trainManagerEntry.aboveTrainLeavingSpeedSign = -1
        end
    end

    -- calculate new speed
    local speed = math.abs(trainManagerEntry.undergroundTrain.speed)
    if trainManagerEntry.aboveTrainLeaving and trainManagerEntry.aboveTrainLeaving.valid then
        local t = trainManagerEntry.aboveTrainLeaving
        if t.state ~= defines.train_state.on_the_path and math.abs(t.speed) < speed then
            speed = math.abs(t.speed)
        end
    end

    trainManagerEntry.speed = speed
    trainManagerEntry.speedLastUpdateTick = game.tick
end

TrainManager.CopyTrainToUnderground = function(trainManagerEntry)
    local placedCarriage, refTrain, tunnel, targetSurface = nil, trainManagerEntry.aboveTrainEntering, trainManagerEntry.tunnel, trainManagerEntry.tunnel.undergroundSurface

    local endSignalRailUnitNumber = trainManagerEntry.surfaceEntrancePortalEndSignal.entity.get_connected_rails()[1].unit_number
    local firstCarriageDistanceFromEndSignal = 0
    for _, railEntity in pairs(refTrain.path.rails) do
        -- TODO: this doesn't account for where on the current rail entity the carriage is, but hopefully is accurate enough.
        local thisRailLength = 2
        if railEntity.type == "curved-rail" then
            thisRailLength = 7 -- Estimate
        end
        firstCarriageDistanceFromEndSignal = firstCarriageDistanceFromEndSignal + thisRailLength
        if railEntity.unit_number == endSignalRailUnitNumber then
            break
        end
    end

    local tunnelInitialPosition =
        Utils.RotatePositionAround0(
        tunnel.alignmentOrientation,
        {
            x = 1 + tunnel.undergroundModifiers.tunnelInstanceValue,
            y = 0
        }
    )
    local nextCarriagePosition =
        Utils.ApplyOffsetToPosition(
        tunnelInitialPosition,
        Utils.RotatePositionAround0(
            trainManagerEntry.trainTravelOrientation,
            {
                x = 0,
                y = tunnel.undergroundModifiers.distanceFromCenterToPortalEndSignals + firstCarriageDistanceFromEndSignal
            }
        )
    )
    local trainCarriagesOffset = Utils.RotatePositionAround0(trainManagerEntry.trainTravelOrientation, {x = 0, y = 7})
    local trainCarriagesForwardDirection = trainManagerEntry.trainTravelDirection
    if not trainManagerEntry.trainTravellingForwards then
        trainCarriagesForwardDirection = Utils.LoopDirectionValue(trainCarriagesForwardDirection + 4)
    end

    local minCarriageIndex, maxCarriageIndex, carriageIterator = 1, #refTrain.carriages, 1
    if trainManagerEntry.aboveTrainEnteringSpeedSign < 0 then
        minCarriageIndex, maxCarriageIndex, carriageIterator = #refTrain.carriages, 1, -1
    end
    for currentSourceTrainCarriageIndex = minCarriageIndex, maxCarriageIndex, carriageIterator do
        local refCarriage = refTrain.carriages[currentSourceTrainCarriageIndex]
        local carriageDirection = trainCarriagesForwardDirection
        if refCarriage.speed ~= refTrain.speed then
            carriageDirection = Utils.LoopDirectionValue(carriageDirection + 4)
        end
        --Utils.OrientationToDirection(refCarriage.orientation)
        placedCarriage = TrainManager.CopyCarriage(targetSurface, refCarriage, nextCarriagePosition, carriageDirection)

        nextCarriagePosition = Utils.ApplyOffsetToPosition(nextCarriagePosition, trainCarriagesOffset)
    end
    return placedCarriage.train
end

TrainManager.CopyCarriage = function(targetSurface, refCarriage, newPosition, newDirection)
    local placedCarriage = targetSurface.create_entity {name = refCarriage.name, position = newPosition, force = refCarriage.force, direction = newDirection}

    local refBurner = refCarriage.burner
    if refBurner ~= nil then
        local placedBurner = placedCarriage.burner
        for fuelName, fuelCount in pairs(refBurner.burnt_result_inventory.get_contents()) do
            placedBurner.burnt_result_inventory.insert({name = fuelName, count = fuelCount})
        end
        placedBurner.heat = refBurner.heat
        placedBurner.currently_burning = refBurner.currently_burning
        placedBurner.remaining_burning_fuel = refBurner.remaining_burning_fuel
    end

    if refCarriage.backer_name ~= nil then
        placedCarriage.backer_name = refCarriage.backer_name
    end
    placedCarriage.health = refCarriage.health
    if refCarriage.color ~= nil then
        placedCarriage.color = refCarriage.color
    end

    -- Finds cargo wagon and locomotives main inventories.
    local refCargoWagonInventory = refCarriage.get_inventory(defines.inventory.cargo_wagon)
    if refCargoWagonInventory ~= nil then
        local placedCargoWagonInventory, refCargoWagonInventoryIsFiltered = placedCarriage.get_inventory(defines.inventory.cargo_wagon), refCargoWagonInventory.is_filtered()
        for i = 1, #refCargoWagonInventory do
            if refCargoWagonInventory[i].valid_for_read then
                placedCargoWagonInventory[i].set_stack(refCargoWagonInventory[i])
            end
            if refCargoWagonInventoryIsFiltered then
                local filter = refCargoWagonInventory.get_filter(i)
                if filter ~= nil then
                    placedCargoWagonInventory.set_filter(i, filter)
                end
            end
        end
        if refCargoWagonInventory.supports_bar() then
            placedCargoWagonInventory.set_bar(refCargoWagonInventory.get_bar())
        end
    end

    return placedCarriage
end

TrainManager.IsTunnelInUse = function(tunnelToCheck)
    for _, managedTrain in pairs(global.trainManager.managedTrains) do
        if managedTrain.tunnel.id == tunnelToCheck.id then
            return true
        end
    end

    for _, portal in pairs(tunnelToCheck.portals) do
        for _, railEntity in pairs(portal.portalRailEntities) do
            if not railEntity.can_be_destroyed() then
                --If the rail can't be destroyed then theres a train carriage on it.
                return true
            end
        end
    end

    return false
end

TrainManager.TunnelRemoved = function(tunnelRemoved)
    for _, managedTrain in pairs(global.trainManager.managedTrains) do
        if managedTrain.tunnel.id == tunnelRemoved.id then
            if managedTrain.aboveTrainEnteringId ~= nil then
                global.trainManager.enteringTrainIdToManagedTrain[managedTrain.aboveTrainEnteringId] = nil
                managedTrain.aboveTrainEntering.schedule = managedTrain.origTrainSchedule
                managedTrain.aboveTrainEntering.manual_mode = true
                managedTrain.aboveTrainEntering.speed = 0
            end
            if managedTrain.aboveTrainLeavingId ~= nil then
                global.trainManager.leavingTrainIdToManagedTrain[managedTrain.aboveTrainLeavingId] = nil
                managedTrain.aboveTrainLeaving.schedule = managedTrain.origTrainSchedule
                managedTrain.aboveTrainLeaving.manual_mode = true
                managedTrain.aboveTrainLeaving.speed = 0
            end
            local undergroundCarriages = Utils.DeepCopy(managedTrain.undergroundTrain.carriages)
            for _, carriage in pairs(undergroundCarriages) do
                carriage.destroy()
            end
            EventScheduler.RemoveScheduledEvents("TrainManager.TrainEnteringOngoing", managedTrain.id)
            EventScheduler.RemoveScheduledEvents("TrainManager.TrainUndergroundOngoing", managedTrain.id)
            EventScheduler.RemoveScheduledEvents("TrainManager.TrainLeavingOngoing", managedTrain.id)
            global.trainManager.managedTrains[managedTrain.id] = nil
        end
    end
end

return TrainManager
