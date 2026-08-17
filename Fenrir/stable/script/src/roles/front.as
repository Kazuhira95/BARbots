// role: FRONT
#include "../types/role_config.as"
#include "../helpers/unit_helpers.as"
#include "../helpers/factory_helpers.as"
#include "../helpers/economy_helpers.as"
#include "../helpers/guard_helpers.as"
#include "../helpers/unitdef_helpers.as"
#include "../helpers/objective_helpers.as"
#include "../helpers/role_limit_helpers.as"
#include "../global.as"
#include "../types/terrain.as"
// Builder state and helpers for enqueueing structures like nanos
#include "../manager/builder.as"

namespace RoleFront {

    /******************************************************************************

    INITIALIZATION

    ******************************************************************************/

    void Front_Init() {
        GenericHelpers::LogUtil("Front role initialization logic executed", 2);

        // Apply FRONT role settings
        aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Front::AllyRange);

        // FRONT-only: Set default fire state for all T1 combat units to 3 (fire at everything)
        // Note: 2 = fire at will, 3 = fire at everything
        array<string> t1Combat = UnitHelpers::GetAllT1CombatUnits();
        for (uint i = 0; i < t1Combat.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(t1Combat[i]);
            if (d is null) continue;
            // Best-effort: if engine exposes fire-state setter, apply it
            // TODO: If SetFireState is not available, consider moving this to behaviour config for this profile only.
            d.SetFireState(3);
        }

        // Default to bot thresholds in Front init
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapBots;
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdBots;
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerBots; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerBots; 
        g_frontVehicleThresholdsApplied = false;

        Front_ApplyStartLimits();

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::FRONT, "FRONT");
    }

    void Front_ApplyStartLimits() {
        dictionary startLimits; 

        // 1 factory per type enforcement
        startLimits.set("armlab", 1);
        startLimits.set("corlab", 1);
        startLimits.set("leglab", 1);
        startLimits.set("armvp", 1);
        startLimits.set("corvp", 1);
        startLimits.set("legvp", 1);

        startLimits.set("armrectr", 10);
        startLimits.set("cornecro", 10);

        startLimits.set("armap", 1);
        startLimits.set("corap", 1);
        startLimits.set("legap", 1);

        // Silos enabled with income gating (600 metal), cap 10 - applied in IncomeLabLimits
        // start limits deliberately omitted; silo cap is set dynamically in Front_IncomeLabLimits

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Front start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    void Front_MainUpdate() {

    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Front_EconomyUpdate() {
    float metalIncome = aiEconomyMgr.metal.income;
        Front_IncomeLimits(metalIncome);
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    // Track if vehicle thresholds have been applied (to avoid reapplying repeatedly)
    bool g_frontVehicleThresholdsApplied = false;

    // One-time scout rush state for the very first T1 land factory (bot or vehicle)
    bool g_frontScoutRushFinished = false;
    int g_frontScoutRushFactoryId = -1;

    // Attempt to enqueue a scout for the one-time scout rush from the first T1 land factory.
    // Returns a task if a scout was enqueued, otherwise null.
    IUnitTask@ Front_TryScoutRush(CCircuitUnit@ u, const string &in factoryName, const string &in side)
    {
        if (u is null) return null;
        if (g_frontScoutRushFinished) return null;
        if (!UnitHelpers::IsT1BotLab(factoryName) && !UnitHelpers::IsT1VehicleLab(factoryName)) return null;

        // Lock to the first T1 land factory encountered
        if (g_frontScoutRushFactoryId == -1) {
            g_frontScoutRushFactoryId = u.id;
            GenericHelpers::LogUtil("[FRONT] ScoutRush locked to factory id=" + g_frontScoutRushFactoryId + " (" + factoryName + ")", 2);
        }
        if (u.id != g_frontScoutRushFactoryId) return null; // only the locked factory performs the rush

        int target = Global::RoleSettings::Front::ScoutRushCount;
        if (target <= 0) { g_frontScoutRushFinished = true; return null; }

        string scoutName = UnitHelpers::GetFrontT1ScoutForFactory(factoryName, side);
        if (scoutName == "") { g_frontScoutRushFinished = true; return null; }

        CCircuitDef@ sdef = ai.GetCircuitDef(scoutName);
        if (sdef is null || !sdef.IsAvailable(ai.frame)) {
            // If unavailable, complete rush to avoid perpetual attempts
            g_frontScoutRushFinished = true;
            return null;
        }

        const AIFloat3 pos = u.GetPos(ai.frame);
        IUnitTask@ last = null;
        for (int i = 0; i < target; ++i) {
            @last = aiFactoryMgr.Enqueue(
                TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, sdef, pos, 64.f)
            );
        }
        g_frontScoutRushFinished = true;
        GenericHelpers::LogUtil("[FRONT] ScoutRush enqueued count=" + target, 2);
        return last;
    }

    // Ensure T1 labs recruit a minimum number of constructors
    // - T1 Bot Lab: at least 2 T1 bot constructors (ck)
    // - T1 Vehicle Plant: at least 2 T1 vehicle constructors (cv)
    IUnitTask@ Front_FactoryAiMakeTask(CCircuitUnit@ u)
    {
        if (u is null) return aiFactoryMgr.DefaultMakeTask(u);
        const CCircuitDef@ facDef = u.circuitDef;
        if (facDef is null) return aiFactoryMgr.DefaultMakeTask(u);

        string factoryName = facDef.GetName();
        string side = UnitHelpers::GetSideForUnitName(factoryName);

        // T1 Bot Lab enforcement
        if (UnitHelpers::IsT1BotLab(factoryName)) {
            array<string> botConstructorNames = UnitHelpers::GetT1BotConstructors(side);
            if (botConstructorNames.length() > 0) {
                string botConstructorName = botConstructorNames[0];
                int existingBotConstructors = UnitDefHelpers::GetUnitDefCount(botConstructorName);
                if (existingBotConstructors < Global::RoleSettings::Front::MinT1BotConstructorCount) {
                    CCircuitDef@ ctorDef = ai.GetCircuitDef(botConstructorName);
                    if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 bot lab
            IUnitTask@ rushTask = Front_TryScoutRush(u, factoryName, side);
            if (rushTask !is null) return rushTask;
        }

        // T1 Vehicle Plant enforcement
        if (UnitHelpers::IsT1VehicleLab(factoryName)) {
            array<string> vehicleConstructorNames = UnitHelpers::GetT1VehicleConstructors(side);
            if (vehicleConstructorNames.length() > 0) {
                string vehicleConstructorName = vehicleConstructorNames[0];
                int existingVehicleConstructors = UnitDefHelpers::GetUnitDefCount(vehicleConstructorName);
                if (existingVehicleConstructors < Global::RoleSettings::Front::MinT1VehicleConstructorCount) {
                    CCircuitDef@ vdef = ai.GetCircuitDef(vehicleConstructorName);
                    if (vdef !is null && vdef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos2 = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, vdef, pos2, 64.f)
                        );
                    }
                }
            }

            // After constructor enforcement, try one-time scout rush for T1 vehicle plant
            IUnitTask@ rushTask2 = Front_TryScoutRush(u, factoryName, side);
            if (rushTask2 !is null) return rushTask2;
        }

        // T1 Air Plant enforcement
        if (UnitHelpers::IsT1AircraftPlant(factoryName)) {
            const AIFloat3 pos = u.GetPos(ai.frame);
            string t1AirCtor = (side == "armada" ? "armca" : (side == "cortex" ? "corca" : (side == "legion" ? "legca" : "")));
            int existingT1AirCtors = UnitDefHelpers::GetUnitDefCount(t1AirCtor);
            if (existingT1AirCtors < 1) {
                CCircuitDef@ ctorDef = ai.GetCircuitDef(t1AirCtor);
                if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                    );
                }
            }

            array<string> t2AirPlantNames = { "armaap", "coraap", "legaap" };
            int t2AirPlantCount = UnitDefHelpers::SumUnitDefCounts(t2AirPlantNames);
            string fighterName = (side == "armada" ? "armfig" : (side == "cortex" ? "corveng" : (side == "legion" ? "legfig" : "")));

            if (t2AirPlantCount < 1) {
                CCircuitDef@ fighterDef = ai.GetCircuitDef(fighterName);
                if (fighterDef !is null && fighterDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, fighterDef, pos, 64.f)
                    );
                }
            } else {
                string gunshipName = (side == "armada" ? "armkam" : (side == "cortex" ? "corbw" : (side == "legion" ? "legmos" : "")));
                CCircuitDef@ gunshipDef = ai.GetCircuitDef(gunshipName);
                if (gunshipDef !is null && gunshipDef.IsAvailable(ai.frame) && AiRandom(0, 3) < 2) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, gunshipDef, pos, 64.f)
                    );
                }
                CCircuitDef@ fighterDef = ai.GetCircuitDef(fighterName);
                if (fighterDef !is null && fighterDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, fighterDef, pos, 64.f)
                    );
                }
            }
        }

        if (UnitHelpers::IsT2AircraftPlant(factoryName)) {
            const AIFloat3 pos = u.GetPos(ai.frame);

            // 1st T2 air plant (primary): fighters (AA interceptors) only
            // 2nd T2 air plant: gunships only
            if (u is Factory::primaryT2AirPlant) {
                string fighterName = (side == "armada" ? "armhawk" : (side == "cortex" ? "corvamp" : (side == "legion" ? "legvenator" : "")));
                CCircuitDef@ fighterDef = ai.GetCircuitDef(fighterName);
                if (fighterDef !is null && fighterDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, fighterDef, pos, 64.f)
                    );
                }
            } else {
                string gunshipName = (side == "armada" ? "armliche" : (side == "cortex" ? "corcrwh" : (side == "legion" ? "legfort" : "")));
                CCircuitDef@ gunshipDef = ai.GetCircuitDef(gunshipName);
                if (gunshipDef !is null && gunshipDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, gunshipDef, pos, 64.f)
                    );
                }
            }
        }

        // T3 land gantry: produce signature experimental units
        if (UnitHelpers::IsLandGantry(factoryName)) {
            IUnitTask@ tSig = Factory::EnqueueGantrySignatureBatch(u, side, /*count*/ 2, Task::Priority::HIGH);
            if (tSig !is null) return tSig;
        }

        // Fall back to default when no rule triggers
        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Front_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        string side = Global::AISettings::Side;

        if (isStart) {
            if (Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, side);
            } else {
                GenericHelpers::LogUtil("[Front_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, side);
            }
        }

        // Non-start (switch): terrain-driven factory selection
        // 1) Use map-configured FactoryWeights if available
        dictionary@ sides = FactoryHelpers::GetSideFactoryWeightsFromMapConfig(Global::Map::Config, Global::AISettings::Role);
        dictionary@ factoryWeights = FactoryHelpers::GetFactoryWeightsFromSide(side, sides);
        if (factoryWeights !is null && factoryWeights.getKeys().length() > 0) {
            string selected = FactoryHelpers::SelectWeightedFactory(factoryWeights);
            if (selected != "") return selected;
        }

        // 2) Fallback: pick the next factory type below its cap
        string t1BotName = UnitHelpers::GetT1BotLabForSide(side);
        string t1VehName = (side == "armada" ? "armvp" : (side == "cortex" ? "corvp" : (side == "legion" ? "legvp" : "")));
        string t1AirName = UnitHelpers::GetT1AirPlantForSide(side);
        string t2BotName = UnitHelpers::GetT2BotLabForSide(side);
        string t2VehName = (side == "armada" ? "armavp" : (side == "cortex" ? "coravp" : (side == "legion" ? "legavp" : "")));
        string t2AirName = UnitHelpers::GetT2AirPlantForSide(side);

        if (UnitDefHelpers::SumUnitDefCounts({ t1BotName }) < 1) {
            CCircuitDef@ def = ai.GetCircuitDef(t1BotName);
            if (def !is null && def.IsAvailable(ai.frame)) return t1BotName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t1VehName }) < 1) {
            CCircuitDef@ def = ai.GetCircuitDef(t1VehName);
            if (def !is null && def.IsAvailable(ai.frame)) return t1VehName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t1AirName }) < 1 && Economy::GetMinMetalIncomeLast10s() >= 60.0f) {
            CCircuitDef@ def = ai.GetCircuitDef(t1AirName);
            if (def !is null && def.IsAvailable(ai.frame)) return t1AirName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t2BotName }) < 1) {
            CCircuitDef@ def = ai.GetCircuitDef(t2BotName);
            if (def !is null && def.IsAvailable(ai.frame)) return t2BotName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t2VehName }) < 1 && Economy::GetMinMetalIncomeLast10s() >= 100.0f) {
            CCircuitDef@ def = ai.GetCircuitDef(t2VehName);
            if (def !is null && def.IsAvailable(ai.frame)) return t2VehName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t2AirName }) < 1) {
            CCircuitDef@ def = ai.GetCircuitDef(t2AirName);
            if (def !is null && def.IsAvailable(ai.frame)) return t2AirName;
        }
        if (UnitDefHelpers::SumUnitDefCounts({ t2AirName }) < 2) {
            CCircuitDef@ def = ai.GetCircuitDef(t2AirName);
            if (def !is null && def.IsAvailable(ai.frame)) return t2AirName;
        }

        return "";
    }

    // Factory unit lifecycle hooks (Front role)
    void Front_FactoryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) {
            GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded: unit=<null>", 2);
            return;
        }

        if (usage != Unit::UseAs::FACTORY)
		return;

        const CCircuitDef@ facDef = unit.circuitDef;

        string factoryName = (facDef is null ? "" : facDef.GetName());
        string unitSide = (facDef is null ? "" : UnitHelpers::GetSideForUnitName(factoryName));

        // If we build a vehicle lab at any point, switch to vehicle thresholds
        if (!g_frontVehicleThresholdsApplied && factoryName != "" && UnitHelpers::IsT1VehicleLab(factoryName)) {
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapVehicles;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdVehicles;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles;
            g_frontVehicleThresholdsApplied = true;
            GenericHelpers::LogUtil("[FRONT] Vehicle lab built; applied vehicle raid/attack thresholds", 2);
        }
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) { //T3 factories ignore spam
            array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
            for (uint i = 0; i < spam.length(); ++i)
                ai.GetCircuitDef(spam[i]).SetIgnore(true);
        }

        GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage + " fac=" + factoryName, 3);

        // Opener build orders: seed the queue with initial units on factory switch
        const AIFloat3 pos = unit.GetPos(ai.frame);
        if (UnitHelpers::IsT1BotLab(factoryName)) {
            array<string> ctorNames = UnitHelpers::GetT1BotConstructors(unitSide);
            if (ctorNames.length() > 0 && UnitDefHelpers::GetUnitDefCount(ctorNames[0]) < 1) {
                CCircuitDef@ ctorDef = ai.GetCircuitDef(ctorNames[0]);
                if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                    aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NORMAL, ctorDef, pos, 64.f));
                }
            }
        } else if (UnitHelpers::IsT1VehicleLab(factoryName)) {
            array<string> ctorNames = UnitHelpers::GetT1VehicleConstructors(unitSide);
            if (ctorNames.length() > 0 && UnitDefHelpers::GetUnitDefCount(ctorNames[0]) < 1) {
                CCircuitDef@ ctorDef = ai.GetCircuitDef(ctorNames[0]);
                if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                    aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NORMAL, ctorDef, pos, 64.f));
                }
            }
        } else if (UnitHelpers::IsT1AircraftPlant(factoryName)) {
            string ctorName = (unitSide == "armada" ? "armca" : (unitSide == "cortex" ? "corca" : (unitSide == "legion" ? "legca" : "")));
            if (UnitDefHelpers::GetUnitDefCount(ctorName) < 1) {
                CCircuitDef@ ctorDef = ai.GetCircuitDef(ctorName);
                if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                    aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NORMAL, ctorDef, pos, 64.f));
                }
            }
        }

        // Enqueue 2 combat units as initial production batch
        if (UnitHelpers::IsT2AircraftPlant(factoryName)) {
            string combatName = (unit is Factory::primaryT2AirPlant)
                ? (unitSide == "armada" ? "armhawk" : (unitSide == "cortex" ? "corvamp" : (unitSide == "legion" ? "legvenator" : "")))
                : (unitSide == "armada" ? "armliche" : (unitSide == "cortex" ? "corcrwh" : (unitSide == "legion" ? "legfort" : "")));
            CCircuitDef@ combatDef = ai.GetCircuitDef(combatName);
            if (combatDef !is null && combatDef.IsAvailable(ai.frame)) {
                aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, combatDef, pos, 64.f));
                aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, combatDef, pos, 64.f));
            }
        }
    }

    void Front_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        //GenericHelpers::LogUtil("[FRONT] FactoryAiUnitRemoved id=" + (unit is null ? -1 : unit.id) + " usage=" + usage, 3);
        // No Front-specific cleanup required; Factory manager handles primary/anchor clearing.
    }

    bool Front_AiIsSwitchTime(int lastSwitchFrame) {
        float frameDelta = float(ai.frame - lastSwitchFrame);
        float metalIncome = Economy::GetMinMetalIncomeLast10s();
        float metalCurrent = aiEconomyMgr.metal.current;
        float value = pow(frameDelta, 0.9f) * metalIncome + metalCurrent * 7.0f;
        return value > 150000.0f;
    }

    bool Front_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        assistRequired = false;
        return true;
    }

    int Front_MakeSwitchInterval() {
        return 1;
    }

    /******************************************************************************

    MILITARY HOOKS

    ******************************************************************************/
    

    /******************************************************************************

    BUILDER HOOKS

    ******************************************************************************/ 

    IUnitTask@ Front_BuilderAiMakeTask(CCircuitUnit@ builder) {
        GenericHelpers::LogUtil("[Front_BuilderAiMakeTask] called for builder", 3);
        if (builder is null) return null; // Defensive check

        // Pre-create and cache a single default task instance; never recreate.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "FRONT");

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return defaultTask;

        // Early return: if the default task represents a resource expansion (MEX/GEO variants), keep it.
        if (defaultTask !is null && defaultTask.GetType() == Task::Type::BUILDER) {
            Task::BuildType dbt = Task::BuildType(defaultTask.GetBuildType());
            if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
                dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP) {
                GenericHelpers::LogUtil("[FRONT] defaultTask is MEX/MEXUP/GEO/GEOUP; returning early", 3);
                return defaultTask;
            }
        }

        // Route T1 constructors (bot, vehicle, air) to FRONT logic; others fallback
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
            float metalIncome = Economy::GetMinMetalIncomeLast10s();
            float energyIncome = Economy::GetMinEnergyIncomeLast10s();
            if (builder is Builder::primaryT1BotConstructor || builder is Builder::secondaryT1BotConstructor
             || builder is Builder::primaryT1VehConstructor || builder is Builder::secondaryT1VehConstructor) {
                return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
            }
            if (builder is Builder::primaryT1AirConstructor || builder is Builder::secondaryT1AirConstructor) {
                return Front_T1AirConstructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
            }
        } else if (ctorTier == 2) {
            // Mirror TECH role routing: handle primary/secondary T2 bot constructors explicitly
            bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            float metalIncome = Economy::GetMinMetalIncomeLast10s();
            float energyIncome = Economy::GetMinEnergyIncomeLast10s();
            float metalCurrent = aiEconomyMgr.metal.current;
            bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::EnergyStorageLowPercent;
            if (builder is Builder::primaryT2BotConstructor || builder is Builder::secondaryT2BotConstructor || builder is Builder::freelanceT2BotConstructor) {
                return Front_T2Constructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
            }
            if (builder is Builder::primaryT2AirConstructor || builder is Builder::secondaryT2AirConstructor || builder is Builder::freelanceT2AirConstructor) {
                return Front_T2AirConstructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
            }
        }
        // Fallback to cached default task
        return defaultTask;
    }

    CCircuitUnit@ energizer1 = null;
	CCircuitUnit@ energizer2 = null;

    void Front_BuilderAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		//LogUtil("BUILDER::AiUnitAdded:" + unit.circuitDef, 2);
		const CCircuitDef@ cdef = unit.circuitDef;
		if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
			return;

		// constructor with BASE attribute is assigned to tasks near base
		if (cdef.costM < 200.f) {
			if (energizer1 is null
				&& (uint(cdef.count) > aiMilitaryMgr.GetGuardTaskNum() || cdef.IsAbleToFly()))
			{
				@energizer1 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		} else {
			if (energizer2 is null) {
				@energizer2 = unit;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
		}

	}

    void Front_BuilderAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (energizer1 is unit)
			@energizer1 = null;
		else if (energizer2 is unit)
			@energizer2 = null;
	}

    void Front_BuilderAiTaskAdded(IUnitTask@ task) {
        GenericHelpers::LogUtil("[Front_BuilderAiTaskAdded] called for task", 3);
    }

    void Front_BuilderAiTaskRemoved(IUnitTask@ task, bool done) {

    }

    /******************************************************************************

    ECONOMY LOGIC

    ******************************************************************************/ 

    void Front_IncomeLimits(float metalIncome) {
        // Apply map limits first (baseline)
        dictionary mapLimits = Global::Map::Config.UnitLimits;
        UnitHelpers::ApplyUnitLimits(mapLimits);

        // Then enforce 1-per-type factory caps and builder limits (override map limits)
        Front_IncomeLabLimits(metalIncome);
        Front_IncomeBuilderLimits(metalIncome);
    }

    void Front_IncomeLabLimits(float metalIncome) {
        string side = Global::AISettings::Side;

        // 1 factory per type: T1 factories
        array<string> t1BotLabs;
        if (side == "armada") {
            t1BotLabs = { "armlab" };
        } else if (side == "cortex") {
            t1BotLabs = { "corlab" };
        } else if (side == "legion") {
            t1BotLabs = { "leglab" };
        } else {
            t1BotLabs = { "armlab", "corlab", "leglab" };
        }
        UnitHelpers::BatchApplyUnitCaps(t1BotLabs, 1);

        array<string> t1VehPlants;
        if (side == "armada") {
            t1VehPlants = { "armvp" };
        } else if (side == "cortex") {
            t1VehPlants = { "corvp" };
        } else if (side == "legion") {
            t1VehPlants = { "legvp" };
        } else {
            t1VehPlants = { "armvp", "corvp", "legvp" };
        }
        UnitHelpers::BatchApplyUnitCaps(t1VehPlants, 1);

        // 1 factory per type: T2 bot lab capped at 1; T2 vehicle plant capped at 1 with income >= 100
        array<string> t2BotLabs;
        if (side == "armada") {
            t2BotLabs = { "armalab" };
        } else if (side == "cortex") {
            t2BotLabs = { "coralab" };
        } else if (side == "legion") {
            t2BotLabs = { "legalab" };
        } else {
            t2BotLabs = { "armalab", "coralab", "legalab" };
        }
        UnitHelpers::BatchApplyUnitCaps(t2BotLabs, 1);

        array<string> t2VehPlants;
        if (side == "armada") {
            t2VehPlants = { "armavp" };
        } else if (side == "cortex") {
            t2VehPlants = { "coravp" };
        } else if (side == "legion") {
            t2VehPlants = { "legavp" };
        } else {
            t2VehPlants = { "armavp", "coravp", "legavp" };
        }
        if (metalIncome >= 100.0f) {
            UnitHelpers::BatchApplyUnitCaps(t2VehPlants, 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(t2VehPlants, 0);
        }

        // Air plants: T1 capped at 1 at 60 income, T2 capped at 2 with graduated income + constructor gating
        array<string> t1AirPlants;
        if (side == "armada") {
            t1AirPlants = { "armap" };
        } else if (side == "cortex") {
            t1AirPlants = { "corap" };
        } else if (side == "legion") {
            t1AirPlants = { "legap" };
        } else {
            t1AirPlants = { "armap", "corap", "legap" };
        }
        if(metalIncome >= 60.0f) {
            UnitHelpers::BatchApplyUnitCaps(t1AirPlants, 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(t1AirPlants, 0);
        }

        array<string> t2AirPlants;
        if (side == "armada") {
            t2AirPlants = { "armaap" };
        } else if (side == "cortex") {
            t2AirPlants = { "coraap" };
        } else if (side == "legion") {
            t2AirPlants = { "legaap" };
        } else {
            t2AirPlants = { "armaap", "coraap", "legaap" };
        }
        int t1AirCtorCount = UnitDefHelpers::SumUnitDefCounts({ "armca", "corca", "legca" });
        if(metalIncome >= 200.0f && t1AirCtorCount > 0) {
            UnitHelpers::BatchApplyUnitCaps(t2AirPlants, 2);
        } else if(metalIncome >= 100.0f && t1AirCtorCount > 0) {
            UnitHelpers::BatchApplyUnitCaps(t2AirPlants, 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(t2AirPlants, 0);
        }

        array<string> gantries = { "armshltx", "armshltxuw", "corgant", "corgantuw", "leggant", "leggantuw", "armapt3", "corapt3", "legapt3" };
        if(metalIncome >= 250.0f) {
            UnitHelpers::BatchApplyUnitCaps(gantries, 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(gantries, 0);
        }

        // Silos: cap 10 when metal income >= 600, disabled otherwise
        array<string> silos;
        if (side == "armada") {
            silos = { "armsilo" };
        } else if (side == "cortex") {
            silos = { "corsilo" };
        } else if (side == "legion") {
            silos = { "legsilo" };
        } else {
            silos = { "armsilo", "corsilo", "legsilo" };
        }
        if(metalIncome >= 600.0f) {
            UnitHelpers::BatchApplyUnitCaps(silos, 10);
        } else {
            UnitHelpers::BatchApplyUnitCaps(silos, 0);
        }
    }

    void Front_IncomeBuilderLimits(float metalIncome) {
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int t1BuilderCap = 5 * int(metalIncome / 20.0f);
        if (t1BuilderCap < 5) t1BuilderCap = 5;

        string side = Global::AISettings::Side;
        array<string> t1Builders;
        if (side == "armada") {
            t1Builders = { "armck", "armcv" };
        } else if (side == "cortex") {
            t1Builders = { "corck", "corcv" };
        } else if (side == "legion") {
            t1Builders = { "legck", "legcv" };
        } else {
            t1Builders = { "armck", "armcv", "corck", "corcv", "legck", "legcv" };
        }

        UnitHelpers::BatchApplyUnitCaps(t1Builders, t1BuilderCap);

        //T2 Builder Cap Logic
        int t2BuilderCap = 5 * int(metalIncome / 40.0f);
        if (t2BuilderCap < 5) t2BuilderCap = 5;

        array<string> t2Builders;
        if (side == "armada") {
            t2Builders = { "armack", "armacv" };
        } else if (side == "cortex") {
            t2Builders = { "corack", "coracv" };
        } else if (side == "legion") {
            t2Builders = { "legack", "legacv" };
        } else {
            t2Builders = { "armack", "armavp", "corack", "coracv", "legack", "legacv" };
        }

        UnitHelpers::BatchApplyUnitCaps(t2Builders, t2BuilderCap);
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/ 

    IUnitTask@ Front_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyStalling, bool isEnergyFull) {
        // Econ snapshot is passed by caller (min over last 10s for incomes)

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Primary constructor branch (Bots)
        if (u is Builder::primaryT1BotConstructor) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

            // Build first T2 Bot Lab when: none exist, none queued, and any trigger is met
            // Triggers (OR):
            //  1) metal income >= configured threshold
            //  2) game time >= 22 minutes
            //  3) stored metal >= T2 bot lab cost
            if (t2LabCount < 1 && !Factory::IsT2LabBuildQueued()) {
                const float incomeTrigger = Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
                const bool timeTriggerMet = (ai.frame >= (22 * 60 * SECOND));
                const bool incomeTriggerMet = (metalIncome >= incomeTrigger);
                bool storedMetalTriggerMet = false;
                string t2LabName = UnitHelpers::GetT2BotLabForSide(unitSide);
                CCircuitDef@ t2LabDef = ai.GetCircuitDef(t2LabName);
                if (t2LabDef !is null) {
                    storedMetalTriggerMet = (aiEconomyMgr.metal.current >= t2LabDef.costM);
                }
                if (incomeTriggerMet || timeTriggerMet || storedMetalTriggerMet) {
                    AIFloat3 anchor2 = Factory::GetT1BotLabPos();
                    IUnitTask@ t2b = Builder::EnqueueT2LabIfNeeded(unitSide, anchor2, SQUARE_SIZE * 30, SECOND * 300);
                    if (t2b !is null) return t2b;
                }
            }

            // After T2 lab attempt: build a T1 nano caretaker when reserves allow
            // Route through centralized per-factory nano selection and enqueue helpers
            {
                float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                    ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
                    : 0.0f;
                if (EconomyHelpers::ShouldBuildT1Nano_ByReserves(
                    /*metalCurrent*/ aiEconomyMgr.metal.current,
                    /*buildWhenOverMetal*/ 500.0f,
                    /*energyPercent*/ energyPercent
                )) {
                    CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                    if (targetFactory !is null) {
                        IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::HIGH);
                        if (tNano !is null) return tNano;
                    }
                }
            }

        }

        // Primary constructor branch (Vehicles)
        if (u is Builder::primaryT1VehConstructor) {
            int t2VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs());
            if (t2VehLabCount < 1 && !Factory::IsT2VehPlantBuildQueued() && metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab && Builder::IsT2VehFactoryOffCooldown()) {
                IUnitTask@ tVeh2 = Builder::EnqueueT2VehiclePlant(Global::AISettings::Side, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                if (tVeh2 !is null) return tVeh2;
            }
            // No special vehicle-only eco tasks for now; default
            return defaultTask;
        }

    return defaultTask;
    }

    IUnitTask@ Front_T1AirConstructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyStalling, bool isEnergyFull) {
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        AIFloat3 anchor = Factory::GetT1AirPlantPos();

        // Build T2 air plant with graduated income thresholds:
        //   1st plant at income >= 100
        //   2nd plant at income >= 200
        array<string> t2AirPlantNames = { "armaap", "coraap", "legaap" };
        int t2AirPlantCount = UnitDefHelpers::SumUnitDefCounts(t2AirPlantNames);
        float requiredIncome = (t2AirPlantCount < 1) ? 100.0f : 200.0f;
        if (t2AirPlantCount < 2 && metalIncome >= requiredIncome) {
            IUnitTask@ tT2Air = Builder::EnqueueT2AirPlant(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 600);
            if (tT2Air !is null) return tT2Air;
        }

        return defaultTask;
    }

    AIFloat3 Front_GetFirstT2FactoryPos() {
        if (Factory::primaryT2BotLab !is null) return Factory::primaryT2BotLab.GetPos(ai.frame);
        if (Factory::primaryT2VehPlant !is null) return Factory::primaryT2VehPlant.GetPos(ai.frame);
        if (Factory::primaryT2AirPlant !is null) return Factory::primaryT2AirPlant.GetPos(ai.frame);
        return AIFloat3(-1.0f, 0.0f, 0.0f);
    }

    // Anti-nuke anchor: offset BEHIND the reference factory (toward our own start spot).
    // The engine picks the final build spot within the shake radius of this anchor, so anchoring
    // on a factory itself lets it land in the factory's exit corridor and block unit spawns.
    // Reference priority: T3 land gantry (widest exit, 7x7 units) > first T2 factory.
    AIFloat3 Front_GetAntiNukeAnchor() {
        AIFloat3 basePos = (Global::Map::NearestMapStartPosition !is null)
            ? Global::Map::NearestMapStartPosition.pos
            : Factory::GetPreferredFactoryPos();

        AIFloat3 refPos;
        float offset;
        bool found = false;
        if (Factory::primaryLandGantry !is null) {
            refPos = Factory::primaryLandGantry.GetPos(ai.frame);
            offset = SQUARE_SIZE * 56;
            found = true;
        } else if (Builder::IsGantryBuildQueued()) {
            // Gantry queued but not yet built: use its build anchor as a proxy
            refPos = Factory::GetPreferredFactoryPos();
            offset = SQUARE_SIZE * 56;
            found = true;
        } else {
            AIFloat3 t2Pos = Front_GetFirstT2FactoryPos();
            if (t2Pos.x >= 0.0f) {
                refPos = t2Pos;
                offset = SQUARE_SIZE * 40;
                found = true;
            }
        }
        if (!found) return AIFloat3(-1.0f, 0.0f, 0.0f);

        // XZ direction from reference factory toward our base (behind the factory)
        float dx = basePos.x - refPos.x;
        float dz = basePos.z - refPos.z;
        float len = sqrt(dx * dx + dz * dz);
        if (len > 1.0f) {
            dx = dx / len;
            dz = dz / len;
        } else {
            dx = 0.0f;
            dz = 1.0f;
        }
        return AIFloat3(refPos.x + dx * offset, refPos.y, refPos.z + dz * offset);
    }

    IUnitTask@ Front_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        // Copy of TECH T2 constructor logic with Front-specific gating:
        // - Before 20 minutes of game time, force eco: only build energy converter/AFUS/FUS (skip gantry/nuke/anti-nuke)
        // - After 20 minutes, allow full TECH-style sequence (gantry, nuke, anti-nuke, etc.)

        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Freelance T2 constructors just do default tasks
        if (u is Builder::freelanceT2BotConstructor) {
            return defaultTask;
        }

        const bool isPrimary = (u is Builder::primaryT2BotConstructor || u is Builder::primaryT2VehConstructor);
        const bool isSecondary = (u is Builder::secondaryT2BotConstructor);

        AIFloat3 anchor = Factory::GetT2BotLabPos();

        // Anti-nuke: build one early if none exists (before 20 min, whenever a T2 constructor is free)
        if (EconomyHelpers::GetAntiNukeCount() < 1) {
            AIFloat3 antiAnchor = Front_GetAntiNukeAnchor();
            if (antiAnchor.x >= 0.0f) {
                IUnitTask@ tAmd = Builder::EnqueueAntiNuke(unitSide, antiAnchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tAmd !is null) return tAmd;
            }
        }

        if (isPrimary) {
            // Fusion Reactor
            if (EconomyHelpers::ShouldBuildFusionReactor(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForFUS,
                /*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForFUS,
                /*maxEi*/ Global::RoleSettings::Tech::MaxEnergyIncomeForFUS
            )) {
                IUnitTask@ tFus2 = Builder::EnqueueFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus2 !is null) return tFus2;
            }
        } 

        return defaultTask;
    }

    IUnitTask@ Front_T2AirConstructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        AIFloat3 anchor = Factory::GetT2AirPlantPos();

        // Anti-nuke: build one early if none exists
        if (EconomyHelpers::GetAntiNukeCount() < 1) {
            AIFloat3 antiAnchor = Front_GetAntiNukeAnchor();
            if (antiAnchor.x >= 0.0f) {
                IUnitTask@ tAmd = Builder::EnqueueAntiNuke(unitSide, antiAnchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tAmd !is null) return tAmd;
            }
        }

        // Build additional T2 air plants when income >= 200 and below cap (max 2)
        array<string> t2AirPlantNames = { "armaap", "coraap", "legaap" };
        int t2AirPlantCount = UnitDefHelpers::SumUnitDefCounts(t2AirPlantNames);
        if (t2AirPlantCount < 2 && metalIncome >= 200.0f) {
            IUnitTask@ tT2Air = Builder::EnqueueT2AirPlant(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 600);
            if (tT2Air !is null) return tT2Air;
        }

        return defaultTask;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Front_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::FRONT) match = true;
       
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] FRONT", 2); 
        }

        return match;
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::FRONT) !is null) return; // already
        RoleConfig@ cfg = RoleConfig(AiRole::FRONT, cast<MainUpdateDelegate@>(@Front_MainUpdate));

        @cfg.InitHandler = cast<InitDelegate@>(@Front_Init);
       
        @cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate@>(@Front_AiIsSwitchTime);
        @cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate@>(@Front_AiIsSwitchAllowed);
        @cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate@>(@Front_MakeSwitchInterval);

        @cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_BuilderAiMakeTask);
        @cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate@>(@Front_FactoryAiMakeTask);

        @cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_BuilderAiUnitAdded);
        @cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_BuilderAiUnitRemoved);

        @cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate@>(@Front_BuilderAiTaskAdded);
        @cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate@>(@Front_BuilderAiTaskRemoved);

        @cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate@>(@Front_EconomyUpdate);
       
        @cfg.SelectFactoryHandler = cast<SelectFactoryDelegate@>(@Front_SelectFactoryHandler);
        @cfg.FactoryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_FactoryAiUnitAdded);
        @cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_FactoryAiUnitRemoved);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Front_RoleMatch);

        RoleConfigs::Register(cfg);
    }
}