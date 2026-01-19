if Config.Framework == 'ESX' then
    ESX = exports["es_extended"]:getSharedObject()
elseif Config.Framework == 'QBCORE' then
    QBCore = exports['qb-core']:GetCoreObject()
end

-- TABLES --
-- Tables to keep track of spawned police units
local spawnedVehicles = {} -- {vehNetID = {vehicle = vehEntity, officers = {pedNetID = pedEntity, ...}, officerTasks = {pedNetID = 'TaskName', ...}} }
local deadPeds = {} -- {pedNetID = { officer = pedEntity, timer = 0}}
local farOfficers = {} -- same
local spawnedHeliUnits = {}
local deadHeliPeds = {}
local farHeliPeds = {}
local spawnedAirUnits = {}
local deadAirPeds = {}
local farAirPeds = {}
local stuckAttempts = {} -- {vehNetID = count}
local stolenVehicles = {} -- {vehNetID = vehNetID}
local isSpawning = false -- Variable to prevent spawning more units when spawning is already in progress.
local disableAIPolice = nil -- Toggle to turn AI police response on and off if players are online or not if that config option is used.

-- EXPORTS --
-- Use this in other scripts to set a wanted level (e.g., from robbery scripts).
exports('SetWantedLevel', function(level)
    SetPlayerWantedLevel(PlayerId(), level, false)
    SetPlayerWantedLevelNow(PlayerId(), false)
    if Config.isDebug then print('Set wanted level to ' .. level) end
end)

-- Alias for the same function (if needed for compatibility).
exports('ApplyWantedLevel', function(level)
    SetPlayerWantedLevel(PlayerId(), level, false)
    SetPlayerWantedLevelNow(PlayerId(), false)
    if Config.isDebug then print('Applied wanted level ' .. level) end
end)

-- POLICE COUNT THREAD (consolidated - runs once) --
Citizen.CreateThread(function()
    while true do
        local polCount = 0
        if Config.Framework == 'ESX' then
            local players = ESX.GetPlayers()
            for _, playerId in pairs(players) do
                local xPlayer = ESX.GetPlayerFromId(playerId)
                for _, job in ipairs(Config.PoliceJobsToCheck) do
                    if xPlayer.job.name == job.jobName then
                        if job.onDutyOnly then
                            if xPlayer.job.onduty then
                                polCount = polCount + 1
                            end
                        else
                            polCount = polCount + 1
                        end
                    end
                end
            end
        elseif Config.Framework == 'QBCORE' then
            local players = QBCore.Functions.GetQBPlayers()
            for _, Player in pairs(players) do
                for _, job in ipairs(Config.PoliceJobsToCheck) do
                    if Player.PlayerData.job.name == job.jobName then
                        if job.onDutyOnly then
                            if Player.PlayerData.job.onduty then
                                polCount = polCount + 1
                            end
                        else
                            polCount = polCount + 1
                        end
                    end
                end
            end
        end
        -- -1 source tells ALL clients connected to update their cops online count and do logic pertaining to it.
        TriggerClientEvent('fenix-police:updateCopsOnline', -1, polCount)
        Wait(60000) -- Check every minute
    end
end)

-- **HELPER FUNCTIONS** --
-- SPAWNING --
-- Get player zone for determining spawn tables
local function getPlayerZoneCode()
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    -- Get the zone name from the player's coordinates
    local zoneName = GetNameOfZone(playerCoords.x, playerCoords.y, playerCoords.z)
    return zoneName
end

-- Function to get the formatted zone key
local function getZoneKey(zoneName)
    return Config.ZoneEnum[zoneName] or zoneName -- Return the mapped key or the original zoneName if not found
end

-- Function to get a safe spawn point on a road near the player
local function getSafeSpawnPoint(playerCoords, minDistance, maxDistance)
    local found = false
    local roadCoords, roadHeading
    while not found do
        local offsetX = math.random(minDistance, maxDistance)
        local offsetY = math.random(minDistance, maxDistance)
        if math.random(0, 1) == 0 then offsetX = -offsetX end
        if math.random(0, 1) == 0 then offsetY = -offsetY end
        local spawnCoords = vector3(playerCoords.x + offsetX, playerCoords.y + offsetY, playerCoords.z)
        -- Try major roads first nodeType = 0
        local roadFound, tempRoadCoords, tempRoadHeading = GetClosestVehicleNodeWithHeading(spawnCoords.x, spawnCoords.y, spawnCoords.z, 0, 3.0, 0)
        if not roadFound then
            -- Try any path next nodeType = 1, this approach should prevent cops spawning in fields/racetracks etc. when main roads are available.
            -- But still allow for dirt roads, fields, racetracks, parks etc. as a fallback option.
            roadFound, tempRoadCoords, tempRoadHeading = GetClosestVehicleNodeWithHeading(spawnCoords.x, spawnCoords.y, spawnCoords.z, 1, 3.0, 0)
        end
        if roadFound then
            roadCoords = tempRoadCoords
            roadHeading = tempRoadHeading
            found = true
        end
    end
    if found then
        return roadCoords, roadHeading
    end
    return nil
end

-- Get air unit spawn point within range
local function getRandomPointInRange(playerCoords, minDistance, maxDistance, minHeight, maxHeight)
    local minDist = minDistance or 300
    local maxDist = maxDistance or 500
    if not minDistance then
        if Config.isDebug then print('GetRandomPointInRange: minDistance was nil, using default') end
    end
    if not maxDistance then
        if Config.isDebug then print('GetRandomPointInRange: maxDistance was nil, using default') end
    end
    local offsetX = math.random(minDist, maxDist)
    local offsetY = math.random(minDist, maxDist)
    if math.random(0, 1) == 0 then offsetX = -offsetX end
    if math.random(0, 1) == 0 then offsetY = -offsetY end
    local x = playerCoords.x + offsetX
    local y = playerCoords.y + offsetY
    local z = playerCoords.z + math.random(minHeight, maxHeight)
    return vector3(x, y, z)
end

-- VEHICLE FUNCTIONS --
-- Function to check if a vehicle contains any ped
local function isVehicleOccupied(vehicle)
    if DoesEntityExist(vehicle) then
        for seat = -1, GetVehicleMaxNumberOfPassengers(vehicle) do
            local ped = GetPedInVehicleSeat(vehicle, seat)
            if ped and ped ~= 0 then
                return true -- There is a ped in the vehicle
            end
        end
    end
    return false -- No ped found in the vehicle
end

-- Check if the vehicle seems stuck
function IsVehicleStuck(vehicle)
    if not DoesEntityExist(vehicle) or not IsPedInAnyVehicle(GetPedInVehicleSeat(vehicle, -1), false) then
        return false
    end
    local vehicleSpeed = GetEntitySpeed(vehicle)
    local isStuck = false
    if vehicleSpeed < 0.2 then
        local stuckTime = 0
        while vehicleSpeed < 0.2 and stuckTime < 8000 do -- Check if the vehicle is stuck for 8 seconds
            Citizen.Wait(1000)
            vehicleSpeed = GetEntitySpeed(vehicle)
            stuckTime = stuckTime + 1000
        end
        -- If stuck for 8 seconds continuously set isStuck = true.
        if stuckTime >= 8000 then
            isStuck = true
        end
    end
    return isStuck
end

-- Function to continuously check if a vehicle is stuck (fixed - no police count loop)
function MonitorVehicle(vehNetID)
    Citizen.CreateThread(function()
        while spawnedVehicles[vehNetID] do
            local vehicle = NetToVeh(vehNetID)
            local waitCount = 0
            while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
                vehicle = NetToVeh(vehNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if DoesEntityExist(vehicle) and IsVehicleStuck(vehicle) then
                local isLeft = math.random() < 0.5
                GetVehicleUnstuck(vehicle, isLeft, vehNetID)
            end
            Wait(1000) -- Check every second
        end
    end)
end

-- If stuck try reversing and then driving forward left or forward right before going back to task.
function GetVehicleUnstuck(vehicle, isLeft, vehNetID)
    local driver = GetPedInVehicleSeat(vehicle, -1)
    local maxUnstuckAttempts
    if DoesEntityExist(driver) then
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local officerCoords = GetEntityCoords(driver)
        local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)
        if distance > 200 then
            maxUnstuckAttempts = Config.maxFarUnstuckAttempts
            if stuckAttempts[vehNetID] == maxUnstuckAttempts then
                stuckAttempts[vehNetID] = stuckAttempts[vehNetID] + 1
            elseif stuckAttempts[vehNetID] < maxUnstuckAttempts then
                local taskSequence = OpenSequenceTask(0)
                TaskVehicleTempAction(0, vehicle, 28, 4000) -- Strong brake + reverse
                if isLeft then
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it left') end
                    TaskVehicleTempAction(0, vehicle, 7, 2000) -- Turn left + accelerate
                else
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it right') end
                    TaskVehicleTempAction(0, vehicle, 8, 2000) -- Turn right + accelerate
                end
                TaskVehicleTempAction(0, vehicle, 27, 2000) -- Brake until car stop or until time ends
                CloseSequenceTask(taskSequence)
                ClearPedTasks(driver)
                TaskPerformSequence(driver, taskSequence)
                ClearSequenceTask(taskSequence)
                Wait(10000)
                TaskVehicleChase(driver, playerPed)
                stuckAttempts[vehNetID] = (stuckAttempts[vehNetID] or 0) + 1
            end
        else
            maxUnstuckAttempts = Config.maxCloseUnstuckAttempts
            if stuckAttempts[vehNetID] == maxUnstuckAttempts then
                GetPedsOutOfVehicle(vehicle)
                if Config.isDebug then print('Abandoned nearby stuck vehicle ' .. vehNetID) end
                stuckAttempts[vehNetID] = 999
                return
            elseif stuckAttempts[vehNetID] < maxUnstuckAttempts then
                local taskSequence = OpenSequenceTask(0)
                TaskVehicleTempAction(0, vehicle, 28, 4000) -- Strong brake + reverse
                if isLeft then
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it left') end
                    TaskVehicleTempAction(0, vehicle, 7, 2000) -- Turn left + accelerate
                else
                    if Config.isDebug then print('Vehicle ' .. vehNetID .. ' seems stuck, trying to free it right') end
                    TaskVehicleTempAction(0, vehicle, 8, 2000) -- Turn right + accelerate
                end
                TaskVehicleTempAction(0, vehicle, 27, 2000) -- Brake until car stop or until time ends
                CloseSequenceTask(taskSequence)
                ClearPedTasks(driver)
                TaskPerformSequence(driver, taskSequence)
                ClearSequenceTask(taskSequence)
                Wait(10000)
                TaskVehicleChase(driver, playerPed)
                stuckAttempts[vehNetID] = (stuckAttempts[vehNetID] or 0) + 1
            end
        end
    end
end

-- Abandon a vehicle, usually due to being stuck on roof.
function GetPedsOutOfVehicle(vehicle)
    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))
    for i = -1, seats - 2 do
        local ped = GetPedInVehicleSeat(vehicle, i)
        if DoesEntityExist(ped) then
            TaskLeaveVehicle(ped, vehicle, 0)
        end
    end
end

-- Function to handle if the server tried to delete a vehicle and someone was in driver seat still.
RegisterNetEvent('deleteSpawnedVehicleResponseStolen')
AddEventHandler('deleteSpawnedVehicleResponseStolen', function(vehNetID)
    -- Add to stolen vehicle list to delete later.
    stolenVehicles[vehNetID] = vehNetID
    if Config.isDebug then print('Added vehicle/heli/air ID ' .. vehNetID .. ' to stolenVehicles table ') end
end)

-- MAIN LOGIC --
-- AIR UNITS --
-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them.
local function spawnHeliUnitNet(wantedLevel, spawnTable)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    -- Get a safe spawn point
    local spawnCoords = getRandomPointInRange(playerCoords, Config.minHeliSpawnDistance, Config.maxHeliSpawnDistance, Config.minHeliSpawnHeight, Config.maxHeliSpawnHeight)
    if not spawnCoords then
        if Config.isDebug then print('No safe spawn point found for heli') end
        return
    end
    TriggerServerEvent('spawnPoliceHeliNet', wantedLevel, playerCoords, spawnCoords, spawnTable)
end

-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client.
RegisterNetEvent('spawnPoliceHeliNetResponse')
AddEventHandler('spawnPoliceHeliNetResponse', function(vehNetID, officers)
    if Config.isDebug then print('Received heli spawn response for vehNetID ' .. (vehNetID or 'nil')) end
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('HeliSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        SetVehicleEngineOn(vehicle, true, true, false)
        NetworkSetNetworkIdDynamic(vehNetID, false)
        SetNetworkIdCanMigrate(vehNetID, false)
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true)
        spawnedHeliUnits[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }
        for i, pedNetID in ipairs(officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('HeliSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)
            SetPedAsCop(officer, true)
            if i <= 2 then
                SetPedCombatAttributes(officer, 52, true) -- Can vehicle attack? only works on driver
                SetPedCombatAttributes(officer, 53, true) -- Can use mounted vehicle weapons? only works on driver
                SetPedCombatAttributes(officer, 85, true) -- Prefer air targets to targets on ground
                SetPedAccuracy(officer, math.random(20, 30))
            else
                SetPedCombatAttributes(officer, 2, true) -- Allow drive-by shooting.
                SetPedAccuracy(officer, math.random(10, 20))
                SetPedFiringPattern(officer, 0x5D60E4E0) -- Set firing pattern to single shot.
            end
            -- Set the pilot to pursue the player
            if i == 1 then
                TaskVehicleDriveToCoord(officer, vehicle, playerCoords.x, playerCoords.y, playerCoords.z, 60.0, 1, GetEntityModel(vehicle), 16777248, 70.0, true)
                SetDriverAbility(officer, 1.0)
                spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'DriveToCoord'
            else
                spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'None'
            end
            spawnedHeliUnits[vehNetID].officers[pedNetID] = officer
        end
    end
    isSpawning = false
end)

-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them.
local function spawnAirUnitNet(wantedLevel, spawnTable)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    -- Get a safe spawn point
    local spawnCoords = getRandomPointInRange(playerCoords, Config.minAirSpawnDistance, Config.maxAirSpawnDistance, Config.minAirSpawnHeight, Config.maxAirSpawnHeight)
    if not spawnCoords then
        if Config.isDebug then print('No safe spawn point found for air') end
        return
    end
    TriggerServerEvent('spawnPoliceAirNet', wantedLevel, playerCoords, spawnCoords, spawnTable)
end

-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client.
RegisterNetEvent('spawnPoliceAirNetResponse')
AddEventHandler('spawnPoliceAirNetResponse', function(vehNetID, officers)
    if Config.isDebug then print('Received air spawn response for vehNetID ' .. (vehNetID or 'nil')) end
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('AirSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        SetVehicleEngineOn(vehicle, true, true, false)
        NetworkSetNetworkIdDynamic(vehNetID, false)
        SetNetworkIdCanMigrate(vehNetID, false)
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true)
        spawnedAirUnits[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }
        for i, pedNetID in ipairs(officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('AirSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)
            SetPedAsCop(officer, true)
            SetPedCombatAttributes(officer, 52, true)
            SetPedCombatAttributes(officer, 53, true)
            SetPedCombatAttributes(officer, 85, true)
            SetPedCombatAttributes(officer, 86, true)
            SetPedAccuracy(officer, math.random(20, 30))
            GiveWeaponToPed(officer, GetHashKey('VEHICLE_WEAPON_SPACE_ROCKET'), 50, false, true)
            SetCurrentPedVehicleWeapon(officer, GetHashKey('VEHICLE_WEAPON_SPACE_ROCKET'))
            ControlLandingGear(vehicle, 3) -- Retract the gear
            -- Set the pilot to pursue the player
            if i == 1 then
                local playerVeh = GetVehiclePedIsIn(playerPed, false)
                TaskVehicleMission(officer, vehicle, playerVeh, 6, 1000.0, 1073741824, 1, 0.0, true)
                SetDriverAbility(officer, 1.0)
                spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
            else
                spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'None'
            end
            spawnedAirUnits[vehNetID].officers[pedNetID] = officer
        end
    end
    isSpawning = false
end)

-- GROUND UNITS --
-- This function will tell the server to spawn a police unit, and the server will pass back the Network ID of the vehicle + officers spawned so the client can handle them.
local function spawnPoliceUnitNet(wantedLevel)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local zoneCode = getPlayerZoneCode() -- Zone for determining spawnlists
    local zone = Config.zones[zoneCode]
    local regionCode = nil
    if zone then
        regionCode = getZoneKey(zone.location)
    else
        if Config.isDebug then print('ERROR: region enum not found for zoneCode = '.. zoneCode) end
        regionCode = 'losSantos'
    end
    -- Get a safe spawn point
    local spawnPoint, spawnHeading = getSafeSpawnPoint(playerCoords, Config.minPoliceSpawnDistance, Config.maxPoliceSpawnDistance)
    if not spawnPoint then
        if Config.isDebug then print('No safe spawn point found for ground unit') end
        return
    end
    if Config.isDebug then print('Requesting ground unit spawn for wanted level ' .. wantedLevel) end
    TriggerServerEvent('spawnPoliceUnitNet', wantedLevel, playerCoords, regionCode, spawnPoint, spawnHeading)
end

-- This handles the response from the server after a vehicle and officers are spawned, so they can be tasked and otherwise handled by the client.
RegisterNetEvent('spawnPoliceUnitNetResponse')
AddEventHandler('spawnPoliceUnitNetResponse', function(vehNetID, officers)
    if Config.isDebug then print('Received ground spawn response for vehNetID ' .. (vehNetID or 'nil')) end
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    if vehNetID and officers then
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.spawnWaitCount do
            if Config.isDebug then print('UnitSpawn waiting for vehicle = NetToVeh to not be nil or 0') end
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        NetworkSetNetworkIdDynamic(vehNetID, false)
        SetNetworkIdCanMigrate(vehNetID, false)
        SetNetworkIdExistsOnAllMachines(vehNetID, true)
        SetEntityAsMissionEntity(vehicle, true, true)
        spawnedVehicles[vehNetID] = {vehicle = vehicle, officers = {}, officerTasks = {} }
        for i, pedNetID in ipairs(officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.spawnWaitCount do
                if Config.isDebug then print('UnitSpawn waiting for officer = NetToPed to not be nil') end
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            NetworkSetNetworkIdDynamic(pedNetID, false)
            SetNetworkIdCanMigrate(pedNetID, false)
            SetNetworkIdExistsOnAllMachines(pedNetID, true)
            SetEntityAsMissionEntity(officer, true, true)
            SetPedAsCop(officer, true)
            SetPedCombatAttributes(officer, 2, true) -- Able to driveby
            SetPedCombatAttributes(officer, 22, true) -- Drag injured peds to safety
            SetPedAccuracy(officer, math.random(10, 30))
            SetPedFiringPattern(officer, 0xD6FF6D61) -- Set firing pattern to a more controlled burst.
            SetPedGetOutUpsideDownVehicle(officer, true)
            -- Set the driver to pursue the player
            if i == 1 then
                TaskVehicleDriveToCoord(officer, vehicle, playerCoords.x, playerCoords.y, playerCoords.z, 30.0, 1, GetEntityModel(vehicle), 787004, 5.0, true)
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'DriveToCoord'
                SetDriverAbility(officer, 1.0)
                SetDriverAggressiveness(officer, 0.5)
                SetSirenKeepOn(vehicle, true)
            else
                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'None'
            end
            spawnedVehicles[vehNetID].officers[pedNetID] = officer
        end
        -- Will check if vehicle is stuck and try to free it.
        MonitorVehicle(vehNetID)
    end
    isSpawning = false
end)

-- Function to maintain the desired number of police units
local function maintainPoliceUnits(wantedLevel)
    local playerPed = PlayerPedId()
    local playerVeh = GetVehiclePedIsIn(playerPed, false)
    local maxUnits = Config.maxUnitsPerLevel[wantedLevel] or 0
    local currentUnits = 0
    local maxHeliUnits = Config.maxHeliUnitsPerLevel[wantedLevel] or 0
    local currentHeliUnits = 0
    local maxAirUnits = Config.maxAirUnitsPerLevel[wantedLevel] or 0
    local currentAirUnits = 0
    -- Do Ground Units --
    local spawnGroundUnits = false
    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            spawnGroundUnits = Config.spawnGroundUnitsInPlane
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            spawnGroundUnits = Config.spawnGroundUnitsInHeli
        else
            spawnGroundUnits = true
        end
    else
        spawnGroundUnits = true
    end
    if spawnGroundUnits then
        for _, vehicleData in pairs(spawnedVehicles) do
            currentUnits = currentUnits + 1
        end
        if Config.isDebug then print('Current ground units: ' .. currentUnits .. ' / Max: ' .. maxUnits .. ' (isSpawning: ' .. tostring(isSpawning) .. ')') end
        -- Spawn additional units if needed
        while currentUnits < maxUnits and not isSpawning do
            isSpawning = true
            spawnPoliceUnitNet(wantedLevel)
            currentUnits = currentUnits + 1
        end
    end
    -- Do Heli Units --
    local heliSpawnTable = nil
    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            -- We don't spawn helis anymore if player is in a plane.
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            heliSpawnTable = Config.milHelis
        else
            heliSpawnTable = Config.polHelis
        end
    else
        heliSpawnTable = Config.polHelis
    end
    if heliSpawnTable then
        for _, vehicleData in pairs(spawnedHeliUnits) do
            currentHeliUnits = currentHeliUnits + 1
        end
        if Config.isDebug then print('Current heli units: ' .. currentHeliUnits .. ' / Max: ' .. maxHeliUnits .. ' (isSpawning: ' .. tostring(isSpawning) .. ')') end
        while currentHeliUnits < maxHeliUnits and not isSpawning do
            isSpawning = true
            spawnHeliUnitNet(wantedLevel, heliSpawnTable)
            currentHeliUnits = currentHeliUnits + 1
        end
    end
    -- Do Air Units --
    local airSpawnTable = nil
    if playerVeh ~= 0 then
        if IsThisModelAPlane(GetEntityModel(playerVeh)) then
            airSpawnTable = Config.milPlanes
        elseif IsThisModelAHeli(GetEntityModel(playerVeh)) then
            airSpawnTable = Config.milPlanes
        else
            -- We don't spawn planes anymore if player is in a car
        end
    else
        -- We don't spawn planes anymore if player is on foot
    end
    if airSpawnTable then
        for _, vehicleData in pairs(spawnedAirUnits) do
            currentAirUnits = currentAirUnits + 1
        end
        if Config.isDebug then print('Current air units: ' .. currentAirUnits .. ' / Max: ' .. maxAirUnits .. ' (isSpawning: ' .. tostring(isSpawning) .. ')') end
        while currentAirUnits < maxAirUnits and not isSpawning do
            isSpawning = true
            spawnAirUnitNet(wantedLevel, airSpawnTable)
            currentAirUnits = currentAirUnits + 1
        end
    end
end

-- Function to handle police foot chase and vehicle retrieval
local function handleChaseBehavior(vehicleData, playerPed, vehNetID)
    local playerCoords = GetEntityCoords(playerPed)
    local vehicle = NetToVeh(vehNetID)
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end
    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleChase vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
    end
    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleChase ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)
            --Equivalent to checkDeadPeds but for farPeds, done here to leverage distance check
            if distance > Config.officerTooFarDistance then
                if farOfficers[pedNetID] then
                    farOfficers[pedNetID].timer = farOfficers[pedNetID].timer + 1
                else
                    farOfficers[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farOfficers[pedNetID] = nil
            end
            if IsPedInAnyVehicle(playerPed, false) then
                -- Player is in a vehicle
                if IsPedInAnyVehicle(officer, false) then
                    if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                        local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskVehicleChase(officer, playerPed)
                            SetTaskVehicleChaseBehaviorFlag(officer, 8, true) -- Turn on boxing and PIT behavior
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    end
                else
                    local nearbyVehicle = QBCore.Functions.GetClosestVehicle(officerCoords, 100, false)
                    if nearbyVehicle then
                        local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'EnterVehicle' then
                            TaskEnterVehicle(officer, nearbyVehicle, 20000, -1, 1.5, 8, 0)
                            spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'EnterVehicle'
                        end
                    end
                end
            else
                -- Player is on foot
                if distance > Config.footChaseDistance then
                    if IsPedInAnyVehicle(officer, false) then
                        if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                            local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                            if taskStatus ~= 'VehicleChase' then
                                TaskVehicleChase(officer, playerPed)
                                SetTaskVehicleChaseBehaviorFlag(officer, 8, true) -- Turn on boxing and PIT behavior
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                            end
                        else
                            local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                            if taskStatus ~= 'CombatPed' then
                                TaskCombatPed(officer, playerPed, 0, 16)
                                spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                            end
                        end
                    end
                else
                    local taskStatus = spawnedVehicles[vehNetID].officerTasks[pedNetID]
                    if taskStatus ~= 'CombatPed' then
                        TaskGoToEntity(officer, playerPed, -1, 5.0, 2.0, 1073741824, 0)
                        TaskCombatPed(officer, playerPed, 0, 16)
                        spawnedVehicles[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                    end
                end
            end
        end
    end
end

-- Function to handle heli chase
local function handleHeliChaseBehavior(vehicleData, playerPed, vehNetID)
    local playerCoords = GetEntityCoords(playerPed)
    local vehicle = NetToVeh(vehNetID)
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end
    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleHeli vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
    end
    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)
            if distance > Config.heliTooFarDistance then
                if farHeliPeds[pedNetID] then
                    farHeliPeds[pedNetID].timer = farHeliPeds[pedNetID].timer + 1
                else
                    farHeliPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farHeliPeds[pedNetID] = nil
            end
            if IsPedInAnyVehicle(playerPed, false) then
                -- Player is in a vehicle
                if IsPedInAnyVehicle(officer, false) then
                    if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskHeliChase(officer, playerPed, 0, 0, 120)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    end
                else
                    local nearbyVehicle = QBCore.Functions.GetClosestVehicle(officerCoords, 100, false)
                    if nearbyVehicle then
                        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'EnterVehicle' then
                            TaskEnterVehicle(officer, nearbyVehicle, 20000, -1, 1.5, 8, 0)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'EnterVehicle'
                        end
                    end
                end
            else
                if IsPedInAnyVehicle(officer, false) then
                    if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskHeliChase(officer, playerPed, 0, 0, 120)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedHeliUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedHeliUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    end
                end
            end
        end
    end
end

-- Function to handle air chase
local function handleAirChaseBehavior(vehicleData, playerPed, vehNetID)
    local playerCoords = GetEntityCoords(playerPed)
    local vehicle = NetToVeh(vehNetID)
    local waitCount = 0
    while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
        vehicle = NetToVeh(vehNetID)
        Wait(Config.netWaitTime)
        waitCount = waitCount + 1
    end
    if (not vehicle or vehicle == 0) then
        if Config.isDebug then print('HandleAir vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
    end
    for pedNetID, officerData in pairs(vehicleData.officers) do
        local officer = NetToPed(pedNetID)
        local waitCount = 0
        while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
            officer = NetToPed(pedNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if not DoesEntityExist(officer) or officer == 0 then
            if Config.isDebug then print('HandleAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
        else
            local officerCoords = GetEntityCoords(officer)
            local distance = Vdist(playerCoords.x, playerCoords.y, playerCoords.z, officerCoords.x, officerCoords.y, officerCoords.z)
            if distance > Config.planeTooFarDistance then
                if farAirPeds[pedNetID] then
                    farAirPeds[pedNetID].timer = farAirPeds[pedNetID].timer + 1
                else
                    farAirPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            else
                farAirPeds[pedNetID] = nil
            end
            if IsPedInAnyVehicle(playerPed, false) then
                local playerVeh = GetVehiclePedIsIn(playerPed, false)
                if IsPedInAnyVehicle(officer, false) then
                    if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskVehicleMission(officer, vehicle, playerVeh, 6, 1000.0, 1073741824, 1, 0.0, true)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    end
                else
                    local nearbyVehicle = QBCore.Functions.GetClosestVehicle(officerCoords, 100, false)
                    if nearbyVehicle then
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'EnterVehicle' then
                            TaskEnterVehicle(officer, nearbyVehicle, 20000, -1, 1.5, 8, 0)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'EnterVehicle'
                        end
                    end
                end
            else
                if IsPedInAnyVehicle(officer, false) then
                    if GetPedInVehicleSeat(GetVehiclePedIsIn(officer), -1) == officer then
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'VehicleChase' then
                            TaskPlaneChase(officer, playerPed, 20, 20, 150)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'VehicleChase'
                        end
                    else
                        local taskStatus = spawnedAirUnits[vehNetID].officerTasks[pedNetID]
                        if taskStatus ~= 'CombatPed' then
                            TaskCombatPed(officer, playerPed, 0, 16)
                            spawnedAirUnits[vehNetID].officerTasks[pedNetID] = 'CombatPed'
                        end
                    end
                end
            end
        end
    end
end

-- Function to check for dead peds and start the timer
local function checkDeadPeds()
    -- Ground Units --
    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadUnit ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if IsPedDeadOrDying(officer, true) then
                if not deadPeds[pedNetID] then
                    deadPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            end
        end
    end
    -- Heli Units --
    for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if IsPedDeadOrDying(officer, true) then
                if not deadHeliPeds[pedNetID] then
                    deadHeliPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            end
        end
    end
    -- Air Units --
    for vehNetID, vehicleData in pairs(spawnedAirUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('CheckDeadAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if IsPedDeadOrDying(officer, true) then
                if not deadAirPeds[pedNetID] then
                    deadAirPeds[pedNetID] = { officer = officer, timer = 0 }
                end
            end
        end
    end
end

-- Function to handle the deletion of dead peds after timer
local function handleDeadPeds()
    -- Ground Units --
    for pedNetID, deadPed in pairs(deadPeds) do
        deadPed.timer = deadPed.timer + 1
        if deadPed.timer >= (Config.deadOfficerCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Removing DeadOfficer ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadPeds[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedVehicles) do
                if Config.isDebug then print('Checking vehNetID = '.. vehNetID .. ' for dead ped = ' ..pedNetID) end
                if vehicleData.officers[pedNetID] then
                    if Config.isDebug then print('Found ped in vehicleData.officers for pedNetID = ' .. pedNetID) end
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Removing DeadOfficerVehicle ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
    -- Heli Units --
    for pedNetID, deadPed in pairs(deadHeliPeds) do
        deadPed.timer = deadPed.timer + 1
        if deadPed.timer >= (Config.deadHeliPilotCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Removing HeliPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadHeliPeds[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Removing DeadOfficerHeli ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedHeliUnits[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
    -- Air Units --
    for pedNetID, deadPed in pairs(deadAirPeds) do
        deadPed.timer = deadPed.timer + 1
        if deadPed.timer >= (Config.deadAirPilotCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Removing AirPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            deadAirPeds[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Removing DeadOfficerAir ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedAirUnits[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
end

-- Function to handle the deletion of far peds after timer
local function handleFarPeds()
    -- Ground Units --
    for pedNetID, farPed in pairs(farOfficers) do
        if farPed.timer >= (Config.farOfficerCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Remove FarOfficer ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farOfficers[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedVehicles) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Remove FarOfficerVehicle ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedVehicles[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
    -- Heli Units --
    for pedNetID, farPed in pairs(farHeliPeds) do
        if farPed.timer >= (Config.farHeliPilotCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Remove FarHeliPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farHeliPeds[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Remove FarOfficerHeli ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedHeliUnits[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
    -- Air Units --
    for pedNetID, farPed in pairs(farAirPeds) do
        if farPed.timer >= (Config.farAirPilotCleanupTimer / Config.scriptFrequencyModulus) then
            if Config.isDebug then print('Remove FarAirPilot ID = ' .. pedNetID) end
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            farAirPeds[pedNetID] = nil
            for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                if vehicleData.officers[pedNetID] then
                    vehicleData.officers[pedNetID] = nil
                    if not next(vehicleData.officers) then
                        if Config.isDebug then print('Remove FarOfficerAir ID = ' .. vehNetID) end
                        TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
                        spawnedAirUnits[vehNetID] = nil
                    end
                    break
                end
            end
        end
    end
end

-- This function handles re-tasking the police when you first lose your wanted level so they drive off and stop pursuing the player.
local function handleEndWantedTasks()
    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedUnit vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedUnit ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if DoesEntityExist(officer) then
                if Config.isDebug then print('Terminating tasks and setting cruise for ped ' .. pedNetID) end
                if IsPedInVehicle(officer, vehicle, false) then
                    ClearPedTasks(officer)
                    TaskVehicleDriveWander(officer, vehicle, 30.0, 262571)
                    SetSirenKeepOn(vehicle, false)
                else
                    ClearPedTasksImmediately(officer)
                    if DoesEntityExist(vehicle) then
                        TaskEnterVehicle(officer, vehicle, 20000, -1, 1.5, 8, 0)
                        TaskVehicleDriveWander(officer, vehicle, 30.0, 262571)
                    else
                        TaskWanderStandard(officer, 10.0, 10)
                    end
                end
            end
        end
    end
    for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedHeli vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedHeli ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if DoesEntityExist(officer) then
                local driver = GetPedInVehicleSeat(vehicle, -1)
                if driver == officer then
                    ClearPedTasks(officer)
                    local flyPoint = getRandomPointInRange(GetEntityCoords(officer), Config.minHeliSpawnDistance, Config.maxHeliSpawnDistance, Config.minHeliSpawnHeight, Config.maxHeliSpawnHeight)
                    if flyPoint then
                        TaskVehicleDriveToCoord(officer, vehicle, flyPoint.x, flyPoint.y, flyPoint.z, 60.0, 1, GetEntityModel(vehicle), 16777248, 70.0, true)
                    end
                else
                    TaskSetBlockingOfNonTemporaryEvents(officer, true)
                    ClearPedTasks(officer)
                    TaskSetBlockingOfNonTemporaryEvents(officer, false)
                end
            end
        end
    end
    for vehNetID, vehicleData in pairs(spawnedAirUnits) do
        local vehicle = NetToVeh(vehNetID)
        local waitCount = 0
        while (not vehicle or vehicle == 0) and waitCount < Config.controlWaitCount do
            vehicle = NetToVeh(vehNetID)
            Wait(Config.netWaitTime)
            waitCount = waitCount + 1
        end
        if (not vehicle or vehicle == 0) then
            if Config.isDebug then print('EndWantedAir vehicle ID ' .. vehNetID .. ' NetToVeh still nil or 0, gave up ') end
        end
        for pedNetID, officerData in pairs(vehicleData.officers) do
            local officer = NetToPed(pedNetID)
            local waitCount = 0
            while (not officer or officer == 0) and waitCount < Config.controlWaitCount do
                officer = NetToPed(pedNetID)
                Wait(Config.netWaitTime)
                waitCount = waitCount + 1
            end
            if not DoesEntityExist(officer) or officer == 0 then
                if Config.isDebug then print('EndWantedAir ped ID ' .. pedNetID .. ' NetToPed still nil or 0, gave up ') end
            end
            if DoesEntityExist(officer) then
                if Config.isDebug then print('Terminating tasks and setting cruise for air ped ' .. pedNetID) end
                local driver = GetPedInVehicleSeat(vehicle, -1)
                if driver == officer then
                    ClearPedTasks(officer)
                    local flyPoint = getRandomPointInRange(GetEntityCoords(officer), Config.minAirSpawnDistance, Config.maxAirSpawnDistance, Config.minAirSpawnHeight, Config.maxAirSpawnHeight)
                    if flyPoint then
                        TaskVehicleDriveToCoord(officer, vehicle, flyPoint.x, flyPoint.y, flyPoint.z, 60.0, 1, GetEntityModel(vehicle), 16777248, 70.0, true)
                    end
                else
                    TaskSetBlockingOfNonTemporaryEvents(officer, true)
                    ClearPedTasks(officer)
                    TaskSetBlockingOfNonTemporaryEvents(officer, false)
                end
            end
        end
    end
end

-- This function handles deleting the police units when you have lost your wanted level and the timer has expired.
local function handleEndWantedDelete()
    -- Remove Ground Units
    for vehNetID, vehicleData in pairs(spawnedVehicles) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            spawnedVehicles[vehNetID].officers[pedNetID] = nil
            if Config.isDebug then print('Cleaned up police officer ' .. pedNetID) end
        end
        if not next(vehicleData.officers) then
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up police vehicle ' .. vehNetID) end
            spawnedVehicles[vehNetID] = nil
        end
    end
    -- Remove Helicopter Units
    for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            spawnedHeliUnits[vehNetID].officers[pedNetID] = nil
            if Config.isDebug then print('Cleaned up heli officer ' .. pedNetID) end
        end
        if not next(vehicleData.officers) then
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up heli unit ' .. vehNetID) end
            spawnedHeliUnits[vehNetID] = nil
        end
    end
    -- Remove Air Units
    for vehNetID, vehicleData in pairs(spawnedAirUnits) do
        for pedNetID, officerData in pairs(vehicleData.officers) do
            TriggerServerEvent('deleteSpawnedPed', pedNetID)
            spawnedAirUnits[vehNetID].officers[pedNetID] = nil
            if Config.isDebug then print('Cleaned up air officer ' .. pedNetID) end
        end
        if not next(vehicleData.officers) then
            TriggerServerEvent('deleteSpawnedVehicle', vehNetID)
            if Config.isDebug then print('Cleaned up air unit ' .. vehNetID) end
            spawnedAirUnits[vehNetID] = nil
        end
    end
    if Config.isDebug then print('All Units Cleaned Up') end
end

-- ENABLE DISPATCH FEATURES --
-- Fixed - now properly enables/disables dispatch based on config
local function UpdateDispatchServices()
    if disableAIPolice then
        for i = 1, 15 do
            EnableDispatchService(i, false)
        end
        if Config.isDebug then print('Disabled AI dispatch services') end
    else
        for i = 1, #Config.AIResponse.dispatchServices do
            EnableDispatchService(i, Config.AIResponse.dispatchServices[i])
        end
        if Config.AIResponse.wantedLevels then
            SetWantedLevelDifficulty(PlayerId(), 1.0) -- Normal wanted
        else
            SetWantedLevelDifficulty(PlayerId(), 0.0) -- No wanted
        end
        if Config.isDebug then print('Enabled AI dispatch services') end
    end
end

-- COPS ONLINE CHECKING --
RegisterNetEvent('fenix-police:updateCopsOnline')
AddEventHandler('fenix-police:updateCopsOnline', function(polCount)
    if polCount >= Config.numberOfPoliceRequired and Config.onlyWhenPlayerPoliceOffline then
        if not disableAIPolice then
            disableAIPolice = true
            UpdateDispatchServices()
            if Config.isDebug then print('Disabled AI police (player cops online)') end
        end
    else
        if disableAIPolice then
            disableAIPolice = false
            UpdateDispatchServices()
            if Config.isDebug then print('Enabled AI police (no/few player cops)') end
        end
    end
    if Config.PoliceWantedProtection and isPlayerPoliceOfficer() then
        SetPlayerWantedLevel(PlayerId(), 0, false)
        SetPlayerWantedLevelNow(PlayerId(), false)
    end
end)

-- checks if a player is one of the police jobs configured and returns true if they are.
local function isPlayerPoliceOfficer()
    local playerData
    if Config.Framework == 'ESX' then
        playerData = ESX.GetPlayerData()
    elseif Config.Framework == 'QBCORE' then
        playerData = QBCore.Functions.GetPlayerData()
    end
    local isPolice = false
    for _, job in ipairs(Config.PoliceJobsToCheck) do
        if playerData.job.name == job.jobName then
            if Config.PlayerPoliceOnlyOnDuty then
                if playerData.job.onduty then
                    isPolice = true
                end
            else
                isPolice = true
            end
        end
    end
    return isPolice
end

-- MONITOR POLICE VEHICLES AND ADD CAMERAMAN FOR LINE OF SIGHT --
-- Monitor police vehicles and spawn cameraman to allow for visibility and detection of player to work correctly.
-- Function to check if the ped model is a cop
function IsCopPed(model)
    local copModels = {
        GetHashKey('s_m_y_cop_01'), -- LSPD
        -- Add more if needed
    }
    for _, copModel in ipairs(copModels) do
        if model == copModel then
            return true
        end
    end
    return false
end

CreateThread(function ()
    local cleanupCameras = false
    while true do
        if GetPlayerWantedLevel(PlayerId()) >= 1 then
            cleanupCameras = true
            local allVehicles = QBCore.Functions.GetVehicles()
            for _, vehicle in pairs(allVehicles) do
                if GetVehicleClass(vehicle) == 18 then
                    CreateThread(function ()
                        local carPos = GetEntityCoords(vehicle)
                        local theDriver = GetPedInVehicleSeat(vehicle, -1)
                        if theDriver then
                            local carheading = GetEntityHeading(theDriver)
                            local pedHash = GetHashKey('s_m_y_cop_01')
                            local cameraman = CreatePed(0, pedHash, carPos.x, carPos.y, carPos.z+10, carheading, false, false)
                            SetPedAiBlipHasCone(cameraman, false)
                            SetPedAsCop(cameraman)
                            SetEntityInvincible(cameraman, true)
                            SetEntityVisible(cameraman, false, 0)
                            SetEntityCompletelyDisableCollision(cameraman, true, false)
                            Wait(250)
                            DeletePed(cameraman)
                        end
                    end)
                end
            end
            Wait(200)
        else
            if cleanupCameras then
                local pedPool = GetGamePool('CPed')
                for _, ped in ipairs(pedPool) do
                    if IsPedHuman(ped) and not IsPedAPlayer(ped) then
                        local pedModel = GetEntityModel(ped)
                        if IsPedInAnyPoliceVehicle(ped) or IsCopPed(pedModel) then
                            if not IsEntityVisible(ped) then
                                if Config.isDebug then print('Found invisible cameraman officer and deleted it') end
                                DeleteEntity(ped)
                            end
                        end
                    end
                end
                cleanupCameras = false
            end
            Wait(10000)
        end
    end
end)

-- MAIN THREAD --
-- Monitor the player's wanted level and maintain police units (added/fixed - this was missing)
Citizen.CreateThread(function()
    local endWantedTimer = 0
    while true do
        local playerPed = PlayerPedId()
        local wantedLevel = GetPlayerWantedLevel(PlayerId())
        if wantedLevel > 0 and not disableAIPolice and not isPlayerPoliceOfficer() then
            if Config.isDebug then print('Entering spawn loop: wantedLevel=' .. wantedLevel .. ', disableAIPolice=' .. tostring(disableAIPolice) .. ', isPolice=' .. tostring(isPlayerPoliceOfficer())) end
            maintainPoliceUnits(wantedLevel)
            checkDeadPeds()
            handleDeadPeds()
            handleFarPeds()
            for vehNetID, vehicleData in pairs(spawnedVehicles) do
                handleChaseBehavior(vehicleData, playerPed, vehNetID)
            end
            for vehNetID, vehicleData in pairs(spawnedHeliUnits) do
                handleHeliChaseBehavior(vehicleData, playerPed, vehNetID)
            end
            for vehNetID, vehicleData in pairs(spawnedAirUnits) do
                handleAirChaseBehavior(vehicleData, playerPed, vehNetID)
            end
            endWantedTimer = 0
        elseif wantedLevel == 0 and (#spawnedVehicles > 0 or #spawnedHeliUnits > 0 or #spawnedAirUnits > 0) then
            if Config.isDebug then print('Entering end wanted loop') end
            handleEndWantedTasks()
            endWantedTimer = endWantedTimer + 1
            if endWantedTimer >= (Config.endWantedCleanupTimer / Config.scriptFrequencyModulus) then
                handleEndWantedDelete()
                endWantedTimer = 0
            end
        else
            if Config.isDebug then print('Not spawning: wantedLevel=' .. wantedLevel .. ', disableAIPolice=' .. tostring(disableAIPolice) .. ', isPolice=' .. tostring(isPlayerPoliceOfficer())) end
        end
        Citizen.Wait(Config.scriptFrequency)
    end
end)
