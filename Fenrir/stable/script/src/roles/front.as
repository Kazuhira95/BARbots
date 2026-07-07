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

        // Initialize T2 bomber defaults: support role, fire state 3
        Front_ApplyT2BomberDefDefaults();

        // Default to bot thresholds in Front init
        aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapBots;
        aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdBots;
        aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerBots; 
        aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerBots; 
        g_frontVehicleThresholdsApplied = false;

        Front_ApplyStartLimits();

        // On landlocked maps, disable hover plants for the FRONT role at init time
        // (reinforced each economy update in Front_IncomeLabLimits).
        if (Global::Map::LandLocked) {
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1HoverPlants(), 0);
            GenericHelpers::LogUtil("[FRONT] Hover plants capped to 0 on landlocked map", 2);
        }

        // Log all strategic objectives with distance from start
        ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::FRONT, "FRONT");
    }

    void Front_ApplyStartLimits() {
        dictionary startLimits; 

        startLimits.set("armrectr", 10);
        startLimits.set("cornecro", 10);

        startLimits.set("armsilo", 10);
        startLimits.set("corsilo", 10);
        startLimits.set("legsilo", 10);

        UnitHelpers::ApplyUnitLimits(startLimits);

        GenericHelpers::LogUtil("Front start limits applied", 3);
    }

    /******************************************************************************

    MAIN HOOKS

    ******************************************************************************/

    void Front_MainUpdate() {
        // Bomber gate logic: poll total T2 bomber count, switch role when threshold met
        int totalBombers = Front_GetTotalT2BomberCount();
        int openThresh = Global::RoleSettings::Air::BomberGateOpenThreshold;
        int closeThresh = Global::RoleSettings::Air::BomberGateCloseThreshold;
        if (!g_frontBomberGateOpen && totalBombers >= openThresh) {
            g_frontBomberGateOpen = true;
            Front_SetMainRoleForAllT2Bombers("bomber");
            // Upgrade tracked bombers built while gate was closed
            array<CCircuitUnit@> compact;
            for (uint i = 0; i < g_frontT2BomberUnits.length(); ++i) {
                CCircuitUnit@ bu = g_frontT2BomberUnits[i];
                if (bu is null) continue;
                compact.insertLast(bu);
            }
            for (uint i = 0; i < compact.length(); ++i) {
                CCircuitUnit@ bu = compact[i];
                if (bu !is null) {
                    bu.AddAttribute(Unit::Attr::SIEGE.type);
                }
            }
            g_frontT2BomberUnits.resize(0);
            GenericHelpers::LogUtil("[Front][Bombers] Gate OPEN: total=" + totalBombers + ", switching defs to bomber role, upgraded tracked bombers", 3);
        } else if (g_frontBomberGateOpen && totalBombers < closeThresh) {
            g_frontBomberGateOpen = false;
            Front_SetMainRoleForAllT2Bombers("support");
            GenericHelpers::LogUtil("[Front][Bombers] Gate CLOSED: total=" + totalBombers + ", reverting defs to support role", 3);
        }
    }

    /******************************************************************************

    ECONOMY HOOKS

    ******************************************************************************/

    void Front_EconomyUpdate() {
        float metalIncome = aiEconomyMgr.metal.income;
        Front_IncomeLimits(metalIncome);

        // Tiered dynamic open-threshold for bomber gate based on metal income
        float mi = Economy::GetMinMetalIncomeLast10s();
        int tier = 0;
        if (mi < 100.0f) {
            tier = 0;
        } else if (mi <= 150.0f) {
            tier = 1;
        } else {
            tier = 2;
        }
        if (tier != g_frontLastBomberOpenTier) {
            int newOpen = (tier == 0 ? 1 : (tier == 1 ? 40 : 100));
            Global::RoleSettings::Air::BomberGateOpenThreshold = newOpen;
            g_frontLastBomberOpenTier = tier;
            GenericHelpers::LogUtil("[Front][Economy] Bomber open threshold set to " + newOpen + " (miMin10s=" + mi + ")", 4);
        }
    }

    /******************************************************************************

    FACTORY HOOKS

    ******************************************************************************/

    // Track if vehicle thresholds have been applied (to avoid reapplying repeatedly)
    bool g_frontVehicleThresholdsApplied = false;

    // One-time scout rush state for the very first T1 land factory (bot or vehicle)
    bool g_frontScoutRushFinished = false;
    int g_frontScoutRushFactoryId = -1;

    // T3 factory progression state
    // Phases: 0=T1 land (botlab/vehicleplant), 1=T1 air, 2=T2 land, 3=T2 air, 4=T3
    // Starts at 0, increments when each phase is satisfied
    int g_frontPhase = 0;
    // Track which factories have been built for each phase
    bool g_hasBuiltT1Land = false;
    bool g_hasBuiltT1Air = false;
    bool g_hasBuiltT2Land = false;
    bool g_hasBuiltT2Air = false;
    // Track the FIRST T1 lab built for phase 0 to ensure we stay in phase 0 until it's built
    string g_firstT1LandFactoryId = "";
    bool g_firstT1LandBuilt = false;

    // Shipyard phase booleans for landlocked maps (prerequisites for T3)
    bool g_hasBuiltT1Sea = false;
    bool g_hasBuiltT2Sea = false;

    // Bomber gate state (dynamic switching between support and bomber roles)
    bool g_frontBomberGateOpen = false;
    int g_frontLastBomberOpenTier = -1;
    // Track actual T2 bomber units built while gate is closed (for SIEGE upgrade on gate-open)
    array<CCircuitUnit@> g_frontT2BomberUnits;

    // Helper: return canonical T2 bomber unitdef names for all sides
    array<string> Front_GetAllT2BomberNames() {
        array<string> names;
        names.insertLast("armpnix");
        names.insertLast("corhurc");
        names.insertLast("legphoenix");
        return names;
    }

    // Helper: set mainRole for all T2 bomber defs
    void Front_SetMainRoleForAllT2Bombers(const string &in mainRole) {
        array<string> names = Front_GetAllT2BomberNames();
        UnitDefHelpers::SetMainRoleFor(names, mainRole);
        GenericHelpers::LogUtil("[Front][Bombers] Set mainRole=" + mainRole + " for T2 bombers", 3);
    }

    // Helper: compute total team count of T2 bombers across all factions
    int Front_GetTotalT2BomberCount() {
        array<string> names = Front_GetAllT2BomberNames();
        return UnitDefHelpers::SumUnitDefCounts(names);
    }

    // Apply defaults to T2 bomber defs: support role, fire state 3
    void Front_ApplyT2BomberDefDefaults() {
        array<string> names = Front_GetAllT2BomberNames();
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d is null) continue;
            d.SetFireState(3);
        }
        Front_SetMainRoleForAllT2Bombers("support");
        GenericHelpers::LogUtil("[Front][Bombers] T2 bomber defaults applied (support role, fire state 3)", 3);
    }

    // Eco-scaled factory switch limit (AltergressiveV2A formula)
    float g_frontSwitchLimit = 5000 * SECOND;

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

        // T1 Aircraft Plant: maintain minimum air constructors and scouts
        if (UnitHelpers::IsT1AircraftPlant(factoryName)) {
            // Maintain T1 air constructors
            array<string> t1AirCtors = UnitHelpers::GetAllT1AirConstructors();
            int t1AirCtorCount = UnitDefHelpers::SumUnitDefCounts(t1AirCtors);
            if (t1AirCtorCount < Global::RoleSettings::Air::MinT1AirConstructorCount) {
                string scoutName = UnitHelpers::GetT1AirScoutForSide(side);
                // Use scout as proxy for T1 air constructor per side
                array<string> sideT1AirCtor;
                if (side == "armada") sideT1AirCtor = {"armca"};
                else if (side == "cortex") sideT1AirCtor = {"corca"};
                else if (side == "legion") sideT1AirCtor = {"legca"};
                else sideT1AirCtor = t1AirCtors;
                if (sideT1AirCtor.length() > 0) {
                    CCircuitDef@ ctorDef = ai.GetCircuitDef(sideT1AirCtor[0]);
                    if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                        );
                    }
                }
            }
            // Maintain T1 air scouts
            string scoutName = UnitHelpers::GetT1AirScoutForSide(side);
            if (scoutName != "") {
                array<string> allScouts = UnitHelpers::GetAllT1AirScouts();
                int scoutCount = UnitDefHelpers::SumUnitDefCounts(allScouts);
                if (scoutCount < Global::RoleSettings::Air::MinAirScoutCount) {
                    CCircuitDef@ scoutDef = ai.GetCircuitDef(scoutName);
                    if (scoutDef !is null && scoutDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos2 = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, scoutDef, pos2, 64.f)
                        );
                    }
                }
            }
        }

        // T2 Aircraft Plant: maintain minimum T2 air constructors
        if (UnitHelpers::IsT2AircraftPlant(factoryName)) {
            array<string> t2AirCtors;
            if (side == "armada") t2AirCtors = {"armaca"};
            else if (side == "cortex") t2AirCtors = {"coraca"};
            else if (side == "legion") t2AirCtors = {"legaca"};
            else t2AirCtors = {"armaca", "coraca", "legaca"};
            if (t2AirCtors.length() > 0) {
                int t2AirCtorCount = UnitDefHelpers::SumUnitDefCounts(t2AirCtors);
                if (t2AirCtorCount < Global::RoleSettings::Air::MinT2AirConstructorCount) {
                    CCircuitDef@ ctorDef = ai.GetCircuitDef(t2AirCtors[0]);
                    if (ctorDef !is null && ctorDef.IsAvailable(ai.frame)) {
                        const AIFloat3 pos = u.GetPos(ai.frame);
                        return aiFactoryMgr.Enqueue(
                            TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f)
                        );
                    }
                }
            }
        }

        // T1 Shipyard: maintain T1 construction ships
        if (UnitHelpers::IsT1Shipyard(factoryName)) {
            array<string> t1SeaCtors = { "armcs", "corcs", "legnavyconship" };
            int have = UnitDefHelpers::SumUnitDefCounts(t1SeaCtors);
            if (have < Global::RoleSettings::Front::MinT1SeaConstructorCount) {
                string ctorName = (side == "armada") ? "armcs" : (side == "cortex") ? "corcs" : "legnavyconship";
                CCircuitDef@ d = ai.GetCircuitDef(ctorName);
                if (d !is null && d.IsAvailable(ai.frame)) {
                    const AIFloat3 pos = u.GetPos(ai.frame);
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d, pos, 64.f)
                    );
                }
            }
        }

        // T2 Shipyard: maintain T2 construction subs
        if (UnitHelpers::IsT2Shipyard(factoryName)) {
            string t2Ctor = (side == "armada") ? "armacsub" : (side == "cortex") ? "coracsub" : "leganavyconsub";
            int have = UnitDefHelpers::GetUnitDefCount(t2Ctor);
            if (have < 1) {
                CCircuitDef@ d2 = ai.GetCircuitDef(t2Ctor);
                if (d2 !is null && d2.IsAvailable(ai.frame)) {
                    const AIFloat3 pos = u.GetPos(ai.frame);
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d2, pos, 64.f)
                    );
                }
            }
        }

        // Fall back to default when no rule triggers
        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Front_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if(isStart) {
            // On landlocked maps, always start with a land factory (bot lab) to avoid
            // expensive hover-start paths. All factions must follow the same build order:
            // land factory -> T1 shipyard -> T2 shipyard.
            if (Global::Map::LandLocked) {
                string side = Global::AISettings::Side;
                GenericHelpers::LogUtil("[Front_SelectFactoryHandler] LandLocked start: forcing bot lab for side=" + side, 1);
                return UnitHelpers::GetT1BotLabForSide(side);
            }

            if(Global::Map::NearestMapStartPosition !is null) {
                return FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            } else {
                GenericHelpers::LogUtil("[Front_SelectFactoryHandler] nearestMapPosition is null", 2);
                return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
            }
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

        // If we build a vehicle lab at any point, switch to vehicle thresholds
        if (!g_frontVehicleThresholdsApplied && factoryName != "" && UnitHelpers::IsT1VehicleLab(factoryName)) {
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapVehicles;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdVehicles;
            aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles;
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles;
            g_frontVehicleThresholdsApplied = true;
            GenericHelpers::LogUtil("[FRONT] Vehicle lab built; applied vehicle raid/attack thresholds", 2);
        }
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) {
            array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
            for (uint i = 0; i < spam.length(); ++i)
                ai.GetCircuitDef(spam[i]).SetIgnore(true);
        }

        // Phase progression detection
        string fName = facDef.GetName();
        if (g_frontPhase == 0 && !g_hasBuiltT1Land &&
            (UnitHelpers::IsT1BotLab(fName) || UnitHelpers::IsT1VehicleLab(fName))) {
            g_hasBuiltT1Land = true;
            g_frontPhase = 1;
            GenericHelpers::LogUtil("[FRONT] Phase 0->1: T1 land factory built", 2);
        } else if (g_frontPhase == 1 && UnitHelpers::IsT1AircraftPlant(fName)) {
            g_hasBuiltT1Air = true;
            g_frontPhase = 2;
            GenericHelpers::LogUtil("[FRONT] Phase 1->2: T1 air plant built", 2);
        } else if (g_frontPhase == 2 &&
                   (UnitHelpers::IsT2BotLab(fName) || UnitHelpers::IsT2VehicleLab(fName))) {
            g_hasBuiltT2Land = true;
            g_frontPhase = 3;
            GenericHelpers::LogUtil("[FRONT] Phase 2->3: T2 land factory built", 2);
        } else if (g_frontPhase == 3 && UnitHelpers::IsT2AircraftPlant(fName)) {
            g_hasBuiltT2Air = true;
            g_frontPhase = 4;
            GenericHelpers::LogUtil("[FRONT] Phase 3->4: T2 air plant built", 2);
        } else if (g_frontPhase == 4 && Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0) {
            g_frontPhase = 5;
            GenericHelpers::LogUtil("[FRONT] Phase 4->5: T3 factory built", 2);
        }

        // Shipyard detection for landlocked T3 gating
        if (Global::Map::LandLocked && UnitHelpers::IsT1Shipyard(fName)) {
            g_hasBuiltT1Sea = true;
            GenericHelpers::LogUtil("[FRONT] T1 shipyard built, shipyard phase tracked", 2);
        }
        if (Global::Map::LandLocked && UnitHelpers::IsT2Shipyard(fName)) {
            g_hasBuiltT2Sea = true;
            GenericHelpers::LogUtil("[FRONT] T2 shipyard built, shipyard phase tracked", 2);
        }

        GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage, 3);
        // Note: Factory registration and preferred anchors are centralized in Factory manager.
        // Front role currently has no additional per-factory behavior here.
    }

    void Front_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        //GenericHelpers::LogUtil("[FRONT] FactoryAiUnitRemoved id=" + (unit is null ? -1 : unit.id) + " usage=" + usage, 3);
        // No Front-specific cleanup required; Factory manager handles primary/anchor clearing.
    }

    /******************************************************************************

    MILITARY UNIT TRACKING (for bomber gate)

    ******************************************************************************/

    // Track newly created military units; record T2 bombers while the gate is closed
    void Front_MilitaryAiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) return;
        if (usage != Unit::UseAs::COMBAT) return;
        const CCircuitDef@ cdef = unit.circuitDef;
        if (cdef is null) return;
        // Only track T2 bombers when the gate is closed
        string uname = cdef.GetName();
        if (!g_frontBomberGateOpen) {
            array<string> t2Names = Front_GetAllT2BomberNames();
            for (uint i = 0; i < t2Names.length(); ++i) {
                if (uname == t2Names[i]) {
                    g_frontT2BomberUnits.insertLast(unit);
                    GenericHelpers::LogUtil("[Front][Bombers] Tracking T2 bomber unit id=" + unit.id + " ('" + uname + "') while gate closed", 4);
                    break;
                }
            }
        }
    }

    void Front_MilitaryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
        if (unit is null) return;
        for (uint i = 0; i < g_frontT2BomberUnits.length(); ++i) {
            if (g_frontT2BomberUnits[i] is unit) {
                g_frontT2BomberUnits.removeAt(i);
                break;
            }
        }
    }

    bool Front_AiIsSwitchTime(int lastSwitchFrame) {
        const float value = pow((ai.frame - lastSwitchFrame), 0.9) * aiEconomyMgr.metal.income + (aiEconomyMgr.metal.current * 7);
        if (value > g_frontSwitchLimit) {
            g_frontSwitchLimit = 5000 * SECOND;
            return true;
        }
        return false;
    }

    bool Front_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        // Phase progression gate: prevent switching to higher-tier factories before the phase allows
        const string name = facDef.GetName();
        if (g_frontPhase < 2 && (UnitHelpers::IsT2BotLab(name) || UnitHelpers::IsT2VehicleLab(name))) {
            assistRequired = false;
            return false;
        }
        if (g_frontPhase < 3 && UnitHelpers::IsT2AircraftPlant(name)) {
            assistRequired = false;
            return false;
        }
        if (Factory::userData[facDef.id].attr & Factory::Attr::T3 != 0 &&
            (g_frontPhase < 4 || (Global::Map::LandLocked && (!g_hasBuiltT1Sea || !g_hasBuiltT2Sea)))) {
            assistRequired = false;
            return false;
        }

        const bool isOK = (armyCost > 1.2f * facDef.costM * float(factoryCount)) || (metalCurrent > facDef.costM);
        assistRequired = !isOK;
        return isOK;
    }

    int Front_MakeSwitchInterval() {
        return AiRandom(Global::RoleSettings::Front::MinAiSwitchTime, Global::RoleSettings::Front::MaxAiSwitchTime) * SECOND;
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
        GenericHelpers::LogUtil("[FRONT] BuilderAiMakeTask: id=" + builder.id + " name=" + builder.circuitDef.GetName() + " LandLocked=" + Global::Map::LandLocked, 1);

        // Pre-create and cache a single default task instance; never recreate.
        IUnitTask@ defaultTask = Builder::MakeDefaultTaskWithLog(builder.id, "FRONT");

        const CCircuitDef@ udef = builder.circuitDef;
        if (udef is null) return defaultTask;

        // Sea constructors: must route BEFORE the MEX/GEO early return so they can
        // build T2 shipyard even when the default task is resource expansion.
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            if (Global::Map::LandLocked) {
                bool isPrimarySea = Builder::primaryT1SeaConstructor !is null && builder.id == Builder::primaryT1SeaConstructor.id;
                bool isSecondarySea = Builder::secondaryT1SeaConstructor !is null && builder.id == Builder::secondaryT1SeaConstructor.id;
                if (isPrimarySea || isSecondarySea) {
                    GenericHelpers::LogUtil("[FRONT] Routing T1 Sea Ctor id=" + builder.id, 1);
                    float metalIncome = Economy::GetMinMetalIncomeLast10s();
                    float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                    return Front_T1SeaConstructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, aiEconomyMgr.isEnergyFull);
                }
            }
        } else if (ctorTier == 2) {
            if (Global::Map::LandLocked) {
                bool isPrimarySea2 = Builder::primaryT2SeaConstructor !is null && builder.id == Builder::primaryT2SeaConstructor.id;
                bool isSecondarySea2 = Builder::secondaryT2SeaConstructor !is null && builder.id == Builder::secondaryT2SeaConstructor.id;
                if (isPrimarySea2 || isSecondarySea2) {
                    bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                    float metalIncome = Economy::GetMinMetalIncomeLast10s();
                    float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                    float metalCurrent = aiEconomyMgr.metal.current;
                    bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::EnergyStorageLowPercent;
                    return Front_T2SeaConstructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
                }
            }
        }

        // Early return: if the default task represents a resource expansion (MEX/GEO variants), keep it.
        if (defaultTask !is null && defaultTask.GetType() == Task::Type::BUILDER) {
            Task::BuildType dbt = Task::BuildType(defaultTask.GetBuildType());
            if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::MEXUP ||
                dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP) {
                GenericHelpers::LogUtil("[FRONT] defaultTask is MEX/MEXUP/GEO/GEOUP; returning early", 3);
                return defaultTask;
            }
            // Phase progression gate: reject any builder task targeting a factory beyond current phase
            if (dbt == Task::BuildType::FACTORY) {
                CCircuitDef@ bdef = defaultTask.GetBuildDef();
                if (bdef !is null) {
                    string bname = bdef.GetName();
                    if ((g_frontPhase < 2 && (UnitHelpers::IsT2BotLab(bname) || UnitHelpers::IsT2VehicleLab(bname))) ||
                        (g_frontPhase < 3 && UnitHelpers::IsT2AircraftPlant(bname)) ||
                        (Factory::userData[bdef.id].attr & Factory::Attr::T3 != 0 &&
                         (g_frontPhase < 4 || (Global::Map::LandLocked && (!g_hasBuiltT1Sea || !g_hasBuiltT2Sea))))) {
                        GenericHelpers::LogUtil("[FRONT] Phase gate rejected task: " + bname + " phase=" + g_frontPhase, 2);
                        return null;
                    }
                }
            }
        }

        // Route T1 land constructors (bot, vehicle, or hover) to FRONT logic
        if (ctorTier == 1) {
            bool isPrimaryBot = Builder::primaryT1BotConstructor !is null && builder.id == Builder::primaryT1BotConstructor.id;
            bool isSecondaryBot = Builder::secondaryT1BotConstructor !is null && builder.id == Builder::secondaryT1BotConstructor.id;
            bool isPrimaryVeh = Builder::primaryT1VehConstructor !is null && builder.id == Builder::primaryT1VehConstructor.id;
            bool isSecondaryVeh = Builder::secondaryT1VehConstructor !is null && builder.id == Builder::secondaryT1VehConstructor.id;
            if (isPrimaryBot || isSecondaryBot || isPrimaryVeh || isSecondaryVeh) {
                // Use same economy snapshot style as T2: min over last 10s for incomes
                bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
                float metalIncome = Economy::GetMinMetalIncomeLast10s();
                float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
            }
            // On landlocked maps, route hover constructors to the same T1 logic so they
            // can build T1 shipyards and follow the same progression as bot/vehicle constructors.
            if (Global::Map::LandLocked) {
                bool isPrimaryHover = Builder::primaryT1HoverConstructor !is null && builder.id == Builder::primaryT1HoverConstructor.id;
                bool isSecondaryHover = Builder::secondaryT1HoverConstructor !is null && builder.id == Builder::secondaryT1HoverConstructor.id;
                if (isPrimaryHover || isSecondaryHover) {
                    bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                    bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
                    float metalIncome = Economy::GetMinMetalIncomeLast10s();
                    float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                    GenericHelpers::LogUtil("[FRONT] Routing T1 hover ctor id=" + builder.id + " to T1 constructor logic (landlocked)", 1);
                    return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
                }
            }
        } else if (ctorTier == 2) {
            // Mirror TECH role routing: handle primary/secondary T2 bot constructors explicitly
            bool isEnergyFull = aiEconomyMgr.isEnergyFull;
            float metalIncome = Economy::GetMinMetalIncomeLast10s();
            float energyIncome = Economy::GetMinEnergyIncomeLast10s();
            float metalCurrent = aiEconomyMgr.metal.current;
            bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::EnergyStorageLowPercent;
            bool isPrimaryT2Bot = Builder::primaryT2BotConstructor !is null && builder.id == Builder::primaryT2BotConstructor.id;
            bool isSecondaryT2Bot = Builder::secondaryT2BotConstructor !is null && builder.id == Builder::secondaryT2BotConstructor.id;
            bool isFreelanceT2Bot = Builder::freelanceT2BotConstructor !is null && builder.id == Builder::freelanceT2BotConstructor.id;
            if (isPrimaryT2Bot || isSecondaryT2Bot || isFreelanceT2Bot) {
                return Front_T2Constructor_AiMakeTask(builder, defaultTask, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent);
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
        // Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
        int cap = int(metalIncome / 35.0f);

        // Scale Tier 2 bot/vehicle lab caps by economy: 35 metal income per lab
        Front_IncomeLabLimits(metalIncome);
        Front_IncomeBuilderLimits(metalIncome);
        Front_IncomeAirLimits(metalIncome);

        //Always apply map limits, regardless of how eco changes labs limits
        dictionary mapLimits = Global::Map::Config.UnitLimits;
        UnitHelpers::ApplyUnitLimits(mapLimits);
    }

    void Front_IncomeLabLimits(float metalIncome) {
        // Hard cap to 1 factory of each type to prevent base clogging
        int landLabCap = 1;

        string side = Global::AISettings::Side;
        array<string> labs;
        if (side == "armada") {
            labs = { "armalab", "armavp" };
        } else if (side == "cortex") {
            labs = { "coralab", "coravp" };
        } else if (side == "legion") {
            labs = { "legalab", "legavp" };
        } else {
            labs = { "armalab", "armavp", "coralab", "coravp", "legalab", "legavp" };
        }

        UnitHelpers::BatchApplyUnitCaps(labs, landLabCap);

        array<string> gantries = { "armshltx", "armshltxuw", "corgant", "corgantuw", "leggant", "legapt3" };
        if(metalIncome >= 250.0f) {
            UnitHelpers::BatchApplyUnitCaps(gantries, 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(gantries, 0);
        }

        //RoleLimitHelpers::GateGantriesByIncome(temp, side, 250.0f, 1);

        // On landlocked maps, disable hover plants for the FRONT role — all factions
        // follow the same land-factory -> T1 shipyard -> T2 shipyard progression.
        if (Global::Map::LandLocked) {
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1HoverPlants(), 0);
        }

        // Shipyard caps for landlocked maps
        if (Global::Map::LandLocked) {
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(), 1);
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), 1);
        } else {
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(), 0);
            UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), 0);
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

        // Sea constructor caps for landlocked maps
        if (Global::Map::LandLocked) {
            array<string> t1SeaCtors = { "armcs", "corcs", "legnavyconship" };
            int t1SeaCtorCap = 2 + int(metalIncome / 20.0f);
            if (t1SeaCtorCap > 10) t1SeaCtorCap = 10;
            UnitHelpers::BatchApplyUnitCaps(t1SeaCtors, t1SeaCtorCap);
        }
    }

    void Front_IncomeAirLimits(float metalIncome) {
        float energyIncome = Economy::GetMinEnergyIncomeLast10s();

        // T1 Air Constructors (all factions)
        array<string> t1AirCtors = UnitHelpers::GetAllT1AirConstructors();
        int t1AirCtorCap = 3 + int(metalIncome / 30.0f);
        if (t1AirCtorCap > 15) t1AirCtorCap = 15;
        UnitHelpers::BatchApplyUnitCaps(t1AirCtors, t1AirCtorCap);

        // T2 Air Constructors (all factions)
        array<string> t2AirCtors = {"armaca", "coraca", "legaca"};
        int t2AirCtorCap = 2 + int(metalIncome / 50.0f);
        if (t2AirCtorCap > 10) t2AirCtorCap = 10;
        UnitHelpers::BatchApplyUnitCaps(t2AirCtors, t2AirCtorCap);

        // Aircraft plant caps from income
        int allowedT1Air = 0;
        int allowedT2Air = EconomyHelpers::AllowedT2AircraftPlantCountFromIncome(
            metalIncome, energyIncome,
            Global::RoleSettings::Tech::RequiredMetalIncomeForT2AircraftPlant,
            Global::RoleSettings::Tech::RequiredEnergyIncomeForT2AircraftPlant
        );
        if (allowedT2Air > 1) {
            allowedT2Air = 1;
        }
        if (allowedT2Air > 0) {
            allowedT1Air = 1;
        }
        // Phase progression override: allow at least 1 T1 air plant once T1 land exists
        if (allowedT1Air < 1 && g_frontPhase >= 1) {
            allowedT1Air = 1;
        }

        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1AircraftPlants(), allowedT1Air);
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2AircraftPlants(), allowedT2Air);

        // T2 bomber cap
        int t2BomberCap = Global::RoleSettings::Air::TargetT2BomberCount;
        array<string> t2Bombers = {"armpnix", "corhurc", "legphoenix"};
        UnitHelpers::BatchApplyUnitCaps(t2Bombers, t2BomberCap);

        // Support fighter cap
        int fighterCap = Global::RoleSettings::Air::TargetSupportFighterCount;
        array<string> t2Fighters = {"armhawk", "corvamp", "legvenator"};
        UnitHelpers::BatchApplyUnitCaps(t2Fighters, fighterCap);

        GenericHelpers::LogUtil("[Front][Air] Limits: t1AirCtors=" + t1AirCtorCap + " t2AirCtors=" + t2AirCtorCap +
            " t1AirPlants=" + allowedT1Air + " t2AirPlants=" + allowedT2Air, 4);
    }

    /******************************************************************************

    BUILDER LOGIC

    ******************************************************************************/ 

    IUnitTask@ Front_T1Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyStalling, bool isEnergyFull) {
        // Econ snapshot is passed by caller (min over last 10s for incomes)

        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Primary constructor branch (Bots)
        bool _isPriBot = Builder::primaryT1BotConstructor !is null && u.id == Builder::primaryT1BotConstructor.id;
        if (_isPriBot) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

            // Fast-track: if we have zero T2 bot labs and ANY trigger is met, build a T2 Bot Lab now.
            // Triggers (OR):
            //  1) metal income >= configured threshold
            //  2) game time >= 22 minutes
            //  3) stored metal >= T2 bot lab cost
            if (g_frontPhase >= 2 && t2LabCount < 1) {
                const float incomeTrigger = Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
                const bool timeTriggerMet = (ai.frame >= (22 * 60 * SECOND));
                const bool incomeTriggerMet = (metalIncome >= incomeTrigger);
                // Resolve T2 lab cost for stored-metal trigger
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

            // Try T2 lab if eco allows (phase >= 2: T1 air must exist first)
            if (g_frontPhase >= 2) {
                bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLab(
                    /*mi*/ metalIncome,
                    /*ei*/ energyIncome,
                    /*metalCurrent*/ aiEconomyMgr.metal.current,
                    /*requiredMetalIncome*/ Global::RoleSettings::Front::MinimumMetalIncomeForT2Lab,
                    /*requiredMetalCurrent*/ Global::RoleSettings::Front::RequiredMetalCurrentForT2Lab,
                    /*requiredEnergyIncome*/ Global::RoleSettings::Front::MinimumEnergyIncomeForT2Lab,
                    /*constructorDef*/ u.circuitDef,
                    /*t2BotLabCount*/ t2LabCount,
                    /*maxAllowed*/ Global::RoleSettings::Front::MaxT2BotLabs,
                    /*hasPrimaryFactory*/ (Factory::primaryT1BotLab !is null)
                );

                if (shouldT2Lab) {
                    AIFloat3 anchor = Factory::GetT1BotLabPos();
                    IUnitTask@ tLab = Builder::EnqueueT2LabIfNeeded(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 300);
                    if (tLab !is null) return tLab;
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

        // Aircraft Plant: build T1 air plant when economy allows (phase >= 1: T1 land must exist first)
        // Shared between bot and vehicle constructors
        if (g_frontPhase >= 1) {
            int t1AirPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1AircraftPlants());
            int t2AirPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
            int allowedT2Air = EconomyHelpers::AllowedT2AircraftPlantCountFromIncome(
                metalIncome, energyIncome,
                Global::RoleSettings::Tech::RequiredMetalIncomeForT2AircraftPlant,
                Global::RoleSettings::Tech::RequiredEnergyIncomeForT2AircraftPlant
            );
            bool shouldT1Air = (t1AirPlants < 1) && (
                (allowedT2Air > 0) ||
                (metalIncome >= Global::RoleSettings::Tech::RequiredMetalIncomeForAirPlant &&
                 energyIncome >= Global::RoleSettings::Tech::RequiredEnergyIncomeForAirPlant &&
                 aiEconomyMgr.metal.current >= Global::RoleSettings::Tech::RequiredMetalCurrentForAirPlant)
            );
            if (shouldT1Air) {
                IUnitTask@ tAir = Builder::EnqueueT1AirFactory(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 30 * SECOND, Task::Priority::HIGH);
                if (tAir !is null) return tAir;
            }
        }

        // T1 Shipyard on landlocked maps (shared between bot and vehicle constructors)
        if (Global::Map::LandLocked) {
            int t1Shipyards = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1Shipyards());
            GenericHelpers::LogUtil("[FRONT] T1Ctor: checking T1 shipyard build: t1Count=" + t1Shipyards + " mi=" + metalIncome + " thr=" + Global::RoleSettings::Front::MinimumMetalIncomeForT1Shipyard, 1);
            if (t1Shipyards < 1 && metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForT1Shipyard) {
                GenericHelpers::LogUtil("[FRONT] T1Ctor: building T1 shipyard", 1);
                IUnitTask@ tSy = Builder::EnqueueT1Shipyard(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 60, 600 * SECOND);
                if (tSy !is null) return tSy;
            }
        }

        // Primary constructor branch (Vehicles)
        bool _isPriVeh = Builder::primaryT1VehConstructor !is null && u.id == Builder::primaryT1VehConstructor.id;
        if (_isPriVeh) {
            int t2VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs());
            // Fast-track first T2 vehicle plant via centralized builder helper
            if (g_frontPhase >= 2 && t2VehLabCount < 1 && metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab && Builder::IsT2VehFactoryOffCooldown()) {
                IUnitTask@ tVeh2 = Builder::EnqueueT2VehiclePlant(Global::AISettings::Side, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                if (tVeh2 !is null) return tVeh2;
            }
            // No special vehicle-only eco tasks for now; default
            return defaultTask;
        }

    return defaultTask;
    }

    IUnitTask@ Front_T1SeaConstructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, float metalIncome, float energyIncome, bool isEnergyFull) {
        bool _isPriSea = Builder::primaryT1SeaConstructor !is null && u.id == Builder::primaryT1SeaConstructor.id;
        bool _isSecSea = Builder::secondaryT1SeaConstructor !is null && u.id == Builder::secondaryT1SeaConstructor.id;
        GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: entered id=" + u.id + " mi=" + aiEconomyMgr.metal.income + " ei=" + aiEconomyMgr.energy.income + " isPrimary=" + _isPriSea + " isSecondary=" + _isSecSea, 1);
        // Use current income (matching SEA role pattern) — min-over-10s can dip below
        // actual income during spending spikes and block T2 shipyard permanently.
        float mi = aiEconomyMgr.metal.income;
        float ei = aiEconomyMgr.energy.income;
        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        if (_isPriSea || _isSecSea) {
            // T2 shipyard upgrade
            int t2ShipyardCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2Shipyards());
            bool hasPrimaryT1Shipyard = (Factory::primaryT1Shipyard !is null);

            // Fast-track T2 shipyard with fallback triggers (OR), matching T2 lab pattern:
            //  1) metal income >= threshold
            //  2) game time >= 22 minutes (unconditional fallback)
            //  3) stored metal >= T2 shipyard cost
            bool incomeTriggerMet = (mi >= Global::RoleSettings::Front::MinimumMetalIncomeForT2Shipyard);
            bool timeTriggerMet = (ai.frame >= (22 * 60 * SECOND));
            bool storedMetalTriggerMet = false;
            string t2SyName = (unitSide == "armada") ? "armasy" : "corasy";
            CCircuitDef@ t2SyDef = ai.GetCircuitDef(t2SyName);
            if (t2SyDef !is null) {
                storedMetalTriggerMet = (aiEconomyMgr.metal.current >= t2SyDef.costM);
            }
            bool t2SyFastTrack = (incomeTriggerMet || timeTriggerMet || storedMetalTriggerMet);
            GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: t2SyFastTrack=" + t2SyFastTrack + " incomeTrigger=" + incomeTriggerMet + " timeTrigger=" + timeTriggerMet + " storedMetalTrigger=" + storedMetalTriggerMet + " t2Count=" + t2ShipyardCount + " hasT1Sy=" + hasPrimaryT1Shipyard + " mi=" + mi + " ei=" + ei + " mc=" + aiEconomyMgr.metal.current, 1);

            if (EconomyHelpers::ShouldBuildT2Shipyard(
                mi, ei, aiEconomyMgr.metal.current,
                (t2SyFastTrack ? 0.0f : Global::RoleSettings::Front::MinimumMetalIncomeForT2Shipyard),
                Global::RoleSettings::Front::RequiredMetalCurrentForT2Shipyard,
                (t2SyFastTrack ? 0.0f : Global::RoleSettings::Front::MinimumEnergyIncomeForT2Shipyard),
                t2ShipyardCount,
                Global::RoleSettings::Front::MaxT2Shipyards,
                hasPrimaryT1Shipyard
            )) {
                GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: ShouldBuildT2Shipyard=TRUE, enqueuing", 1);
                AIFloat3 anchor = Factory::GetT1ShipyardPos();
                IUnitTask@ tT2Sy = Builder::EnqueueT2Shipyard(unitSide, anchor, SQUARE_SIZE * 60, 600 * SECOND);
                if (tT2Sy !is null) {
                    GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: EnqueueT2Shipyard returned task, routing", 1);
                    return tT2Sy;
                }
                GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: ShouldBuildT2Shipyard=TRUE but Enqueue returned null", 1);
            } else {
                GenericHelpers::LogUtil("[FRONT] T1SeaCtorHandler: ShouldBuildT2Shipyard=FALSE, falling through", 1);
            }

            // Naval Energy Converter
            if (EconomyHelpers::ShouldBuildT1EnergyConverter(
                mi, ei,
                aiEconomyMgr.energy.current, aiEconomyMgr.energy.storage,
                Global::RoleSettings::Sea::BuildT1ConvertersUntilMetalIncome,
                Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyIncome,
                Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyCurrentPercent
            )) {
                IUnitTask@ tConv = Builder::EnqueueT1NavalEnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tConv !is null) return tConv;
            }

            // T1 naval nanos
            float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage) : 0.0f;
            if (Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(
                ei, mi,
                Global::RoleSettings::Sea::NanoEnergyPerUnit,
                Global::RoleSettings::Sea::NanoMetalPerUnit,
                Global::RoleSettings::Sea::NanoMaxCount,
                aiEconomyMgr.metal.current,
                Global::RoleSettings::Sea::NanoBuildWhenOverMetal,
                energyPercent
            )) {
                CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                if (targetFactory !is null) {
                    IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::NORMAL);
                    if (tNano !is null) return tNano;
                }
            }

            // Tidals
            if (EconomyHelpers::ShouldBuildT1Solar(ei, Global::RoleSettings::Sea::TidalEnergyIncomeMinimum)) {
                IUnitTask@ tTidal = Builder::EnqueueT1Tidal(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
                if (tTidal !is null) return tTidal;
            }
        }

        return defaultTask;
    }

    IUnitTask@ Front_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {

        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Freelance T2 constructors just do default tasks
        bool _isFreelance = Builder::freelanceT2BotConstructor !is null && u.id == Builder::freelanceT2BotConstructor.id;
        if (_isFreelance) {
            return defaultTask;
        }

        bool _isPriT2Bot = Builder::primaryT2BotConstructor !is null && u.id == Builder::primaryT2BotConstructor.id;
        bool _isPriT2Veh = Builder::primaryT2VehConstructor !is null && u.id == Builder::primaryT2VehConstructor.id;
        bool _isSecT2Bot = Builder::secondaryT2BotConstructor !is null && u.id == Builder::secondaryT2BotConstructor.id;
        const bool isPrimary = (_isPriT2Bot || _isPriT2Veh);
        const bool isSecondary = (_isSecT2Bot);

        AIFloat3 anchor = Factory::GetT2BotLabPos();

        if (isPrimary) {
            // Gantry (phase >= 4: T2 air must exist first; landlocked also needs T1 sea + T2 sea)
            if (g_frontPhase >= 4 && (!Global::Map::LandLocked || (g_hasBuiltT1Sea && g_hasBuiltT2Sea))) {
                int gantryCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllLandGantries());
                if (EconomyHelpers::ShouldBuildGantry(
                    /*mi*/ metalIncome,
                    /*ei*/ energyIncome,
                    /*metalStored*/ metalCurrent,
                    /*currentGantryCount*/ gantryCount,
                    /*metalIncomePerGantry*/ Global::RoleSettings::Tech::MetalIncomePerGantry,
                    /*energyIncomePerGantry*/ Global::RoleSettings::Tech::EnergyIncomePerGantry
                )) {
                    IUnitTask@ tGantry = Builder::EnqueueLandGantry(unitSide);
                    if (tGantry !is null) return tGantry;
                }
            }

            // Fusion Reactor (lower thresholds on landlocked maps)
            float fusReqMi = Global::Map::LandLocked ? 0.0f : Global::RoleSettings::Tech::MinimumMetalIncomeForFUS;
            float fusReqEi = Global::Map::LandLocked ? 200.0f : Global::RoleSettings::Tech::MinimumEnergyIncomeForFUS;
            if (EconomyHelpers::ShouldBuildFusionReactor(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*reqMi*/ fusReqMi,
                /*reqEi*/ fusReqEi,
                /*maxEi*/ Global::RoleSettings::Tech::MaxEnergyIncomeForFUS
            )) {
                IUnitTask@ tFus = Builder::EnqueueFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus !is null) return tFus;
            }

            // T2 Energy Converter
            if (EconomyHelpers::ShouldBuildT2EnergyConverter(
                /*metalIncome*/ metalIncome,
                /*energyIncome*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*energyFull*/ isEnergyFull,
                /*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter,
                /*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForAdvConverter
            )) {
                IUnitTask@ tConv = Builder::EnqueueAdvEnergyConverter(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 60);
                if (tConv !is null) return tConv;
            }

            // Nuke silo
            int nukeTotal = EconomyHelpers::GetNukeSiloCount();
            int nukeQueued = Builder::NukeSiloQueuedCount;
            if (EconomyHelpers::ShouldBuildNuclearSilo(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*queued*/ nukeQueued,
                /*total*/ nukeTotal,
                /*rushCount*/ Global::RoleSettings::Tech::NukeRush,
                /*reqMiRush*/ Global::RoleSettings::Tech::MinimumMetalIncomeForNukeRush,
                /*reqEiRush*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForNukeRush,
                /*reqMiReg*/ Global::RoleSettings::Tech::MinimumMetalIncomeForNuke,
                /*reqEiReg*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForNuke
            )) {
                IUnitTask@ tNuke = Builder::EnqueueNukeSilo(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tNuke !is null) return tNuke;
            }

            // Anti-nuke
            int antiNukeTotal = EconomyHelpers::GetAntiNukeCount();
            int allowedAnti = EconomyHelpers::AllowedAntiNukesFromIncome(
                /*metalIncome*/ metalIncome,
                /*per*/ Global::RoleSettings::Tech::MetalIncomePerAntiNuke
            );
            if (EconomyHelpers::ShouldBuildAntiNuke(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*current*/ antiNukeTotal,
                /*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForAntiNuke,
                /*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForAntiNuke,
                /*minCount*/ Global::RoleSettings::Tech::MinimumAntiNukeCount,
                /*allowed*/ allowedAnti
            )) {
                IUnitTask@ tAmd = Builder::EnqueueAntiNuke(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tAmd !is null) return tAmd;
            }

            // Advanced Fusion Reactor (lower thresholds on landlocked maps — no water afus)
            float afusReqMi = Global::Map::LandLocked ? 40.0f : Global::RoleSettings::Tech::MinimumMetalIncomeForAFUS;
            float afusReqEi = Global::Map::LandLocked ? 1000.0f : Global::RoleSettings::Tech::MinimumEnergyIncomeForAFUS;
            if (EconomyHelpers::ShouldBuildAdvancedFusionReactor(
                /*mi*/ metalIncome,
                /*ei*/ energyIncome,
                /*energy<90%*/ isEnergyLessThan90Percent,
                /*nukeRush*/ Global::RoleSettings::Tech::NukeRush,
                /*nukeSilos*/ nukeTotal,
                /*reqMi*/ afusReqMi,
                /*reqEi*/ afusReqEi
            )) {
                IUnitTask@ tAfus = Builder::EnqueueAFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tAfus !is null) return tAfus;
            }

            // T2 Aircraft Plant (phase >= 3: T2 land must exist first)
            if (g_frontPhase >= 3) {
                int t2AirPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
                int allowedT2Air = EconomyHelpers::AllowedT2AircraftPlantCountFromIncome(
                    metalIncome, energyIncome,
                    Global::RoleSettings::Tech::RequiredMetalIncomeForT2AircraftPlant,
                    Global::RoleSettings::Tech::RequiredEnergyIncomeForT2AircraftPlant
                );
                if (allowedT2Air > 1) {
                    allowedT2Air = 1;
                }
                if (t2AirPlants < allowedT2Air) {
                    int t1AirPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1AircraftPlants());
                    if (t1AirPlants < 1) {
                        IUnitTask@ tAir1 = Builder::EnqueueT1AirFactory(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 30 * SECOND, Task::Priority::HIGH);
                        if (tAir1 !is null) return tAir1;
                    }
                    IUnitTask@ tAir2 = Builder::EnqueueT2AirPlant(unitSide, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                    if (tAir2 !is null) return tAir2;
                }
            }
            }

        return defaultTask;
    }

    IUnitTask@ Front_T2SeaConstructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        AIFloat3 conLocation = u.GetPos(ai.frame);

        bool _isPriT2Sea = Builder::primaryT2SeaConstructor !is null && u.id == Builder::primaryT2SeaConstructor.id;
        bool _isSecT2Sea = Builder::secondaryT2SeaConstructor !is null && u.id == Builder::secondaryT2SeaConstructor.id;
        if (_isPriT2Sea || _isSecT2Sea) {
            // Fusion
            if (EconomyHelpers::ShouldBuildFusionReactor(
                metalIncome, energyIncome, isEnergyLessThan90Percent,
                Global::RoleSettings::Sea::MinimumMetalIncomeForFUS,
                Global::RoleSettings::Sea::MinimumEnergyIncomeForFUS,
                Global::RoleSettings::Sea::MaxEnergyIncomeForFUS
            )) {
                IUnitTask@ tFus = Builder::EnqueueFUS(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus !is null) return tFus;
            }

            // T2 Energy Converter
            if (EconomyHelpers::ShouldBuildT2EnergyConverter(
                metalIncome, energyIncome, isEnergyLessThan90Percent, isEnergyFull,
                Global::RoleSettings::Sea::MinimumMetalIncomeForAdvConverter,
                Global::RoleSettings::Sea::MinimumEnergyIncomeForAdvConverter
            )) {
                IUnitTask@ tConv = Builder::EnqueueAdvEnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 60);
                if (tConv !is null) return tConv;
            }
        }

        return defaultTask;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Front_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        bool match = false;

        if (preferredMapRole == AiRole::FRONT) match = true;
        if (preferredMapRole == AiRole::AIR) match = true;
        if (preferredMapRole == AiRole::TECH) match = true;
        if (preferredMapRole == AiRole::FRONT_TECH) match = true;
       
        if (match) { 
            GenericHelpers::LogUtil("[RoleMatch] FRONT (unified: also handles AIR/TECH/FRONT_TECH)", 2); 
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

        @cfg.MilitaryAiUnitAdded = cast<AiUnitAddedDelegate@>(@Front_MilitaryAiUnitAdded);
        @cfg.MilitaryAiUnitRemoved = cast<AiUnitRemovedDelegate@>(@Front_MilitaryAiUnitRemoved);

        @cfg.RoleMatchHandler = cast<RoleMatchDelegate@>(@Front_RoleMatch);

        RoleConfigs::Register(cfg);
    }
}