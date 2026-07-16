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

        startLimits.set("armrectr", 10);
        startLimits.set("cornecro", 10);

        startLimits.set("armap", 0);
        startLimits.set("corap", 0);
        startLimits.set("legap", 0);

        startLimits.set("armsilo", 0);
        startLimits.set("corsilo", 0);
        startLimits.set("legsilo", 0);

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

    // Build-order cap-transition logging (log once per transition, avoid spam)
    bool g_frontLoggedT1AirCap = false;
    bool g_frontLoggedT2LandCap = false;
    bool g_frontLoggedT2AirCap = false;
    bool g_frontLoggedT3GantryCap = false;
    bool g_frontLoggedNukeCap = false;

    // Switch threshold for factory production switching (AltergressiveV2A-style)
    float g_frontSwitchLimit = 5000.0f * SECOND;

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
        GenericHelpers::LogUtil("[FRONT] FactoryAiMakeTask for '" + factoryName + "'", 0);
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

        // T1 Aircraft Plant: enforce T1 construction aircraft, then default production
        if (UnitHelpers::IsT1AircraftPlant(factoryName)) {
            const AIFloat3 pos = u.GetPos(ai.frame);
            string t1CtorName = (side == "armada" ? "armca" : side == "cortex" ? "corca" : "legca");
            int t1CtorCount = UnitDefHelpers::GetUnitDefCount(t1CtorName);
            if (t1CtorCount < 1) {
                CCircuitDef@ t1CtorDef = ai.GetCircuitDef(t1CtorName);
                if (t1CtorDef !is null && t1CtorDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NOW, t1CtorDef, pos, 64.f)
                    );
                }
            }
            return aiFactoryMgr.DefaultMakeTask(u);
        }

        // T2 Aircraft Plant: enforce T2 construction aircraft, then fighter/heavy split
        if (UnitHelpers::IsT2AircraftPlant(factoryName)) {
            const AIFloat3 pos = u.GetPos(ai.frame);
            int uid = u.id;
            int pT2 = (Factory::primaryT2AirPlant is null ? -1 : Factory::primaryT2AirPlant.id);
            GenericHelpers::LogUtil("[FRONT][T2AIR] MakeTask u.id=" + uid + " primaryT2AirPlant.id=" + pT2 + " isPrimary=" + (u is Factory::primaryT2AirPlant ? 1 : 0) + " mi=" + aiEconomyMgr.metal.income, 0);

            string t2CtorName = (side == "armada" ? "armaca" : side == "cortex" ? "coraca" : "legaca");
            int t2CtorCount = UnitDefHelpers::GetUnitDefCount(t2CtorName);
            GenericHelpers::LogUtil("[FRONT][T2AIR] t2CtorCount=" + t2CtorCount, 0);
            if (t2CtorCount < 1) {
                CCircuitDef@ t2CtorDef = ai.GetCircuitDef(t2CtorName);
                if (t2CtorDef !is null && t2CtorDef.IsAvailable(ai.frame)) {
                    GenericHelpers::LogUtil("[FRONT][T2AIR] Queuing T2 con air", 0);
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NOW, t2CtorDef, pos, 64.f)
                    );
                }
            }

            // 1st T2 air plant: fighters only. 2nd T2 air plant: heavies only.
            if (u is Factory::primaryT2AirPlant) {
                string fighterName = (side == "armada" ? "armhawk" : side == "cortex" ? "corvamp" : "legvenator");
                GenericHelpers::LogUtil("[FRONT][T2AIR] Primary plant, queuing fighter: " + fighterName, 0);
                CCircuitDef@ fighterDef = ai.GetCircuitDef(fighterName);
                if (fighterDef !is null && fighterDef.IsAvailable(ai.frame)) {
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, fighterDef, pos, 64.f)
                    );
                }
                GenericHelpers::LogUtil("[FRONT][T2AIR] Fighter not available, DefaultMakeTask", 0);
                return aiFactoryMgr.DefaultMakeTask(u);
            }

            // 2nd T2 air plant: heavies only with income gates
            string heavyName;
            if (side == "armada") heavyName = "armblade";
            else if (side == "cortex") heavyName = "corcrwh";
            else heavyName = "legfort";

            float metalIncome = aiEconomyMgr.metal.income;
            int heavyCount = UnitDefHelpers::GetUnitDefCount(heavyName);

            int maxHeavy = 0;
            if (metalIncome > 1000.0f) maxHeavy = 10;
            else if (metalIncome > 500.0f) maxHeavy = 6;
            else if (metalIncome > 400.0f) maxHeavy = 4;
            else if (metalIncome > 300.0f) maxHeavy = 2;
            else if (metalIncome > 200.0f) maxHeavy = 1;

            float buyoutThreshold = (side == "armada" ? 1250.0f : side == "cortex" ? 5100.0f : 5600.0f);
            bool canBuyout = (aiEconomyMgr.metal.current >= buyoutThreshold);

            GenericHelpers::LogUtil("[FRONT][T2AIR] heavy=" + heavyName + " mi=" + metalIncome + " count=" + heavyCount + " max=" + maxHeavy + " buyout=" + (canBuyout ? 1 : 0), 0);
            if (canBuyout || heavyCount < maxHeavy) {
                CCircuitDef@ heavyDef = ai.GetCircuitDef(heavyName);
                GenericHelpers::LogUtil("[FRONT][T2AIR] heavyDef=" + (heavyDef is null ? "null" : heavyDef.GetName()) + " avail=" + (heavyDef is null ? 0 : (heavyDef.IsAvailable(ai.frame) ? 1 : 0)), 0);
                if (heavyDef !is null && heavyDef.IsAvailable(ai.frame)) {
                    GenericHelpers::LogUtil("[FRONT][T2AIR] Queuing heavy: " + heavyName, 0);
                    return aiFactoryMgr.Enqueue(
                        TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::NORMAL, heavyDef, pos, 64.f)
                    );
                }
            }
            GenericHelpers::LogUtil("[FRONT][T2AIR] Falling through to DefaultMakeTask", 0);
            return aiFactoryMgr.DefaultMakeTask(u);
        }

        return aiFactoryMgr.DefaultMakeTask(u);
    }

    string Front_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset) {
        if(isStart) {
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

        GenericHelpers::LogUtil("[FRONT] FactoryAiUnitAdded id=" + unit.id + " usage=" + usage, 3);
    }

    void Front_FactoryAiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
    {
    }

    bool Front_AiIsSwitchTime(int lastSwitchFrame) {
        const float value = pow(float(ai.frame - lastSwitchFrame), 0.9f) * aiEconomyMgr.metal.income + (aiEconomyMgr.metal.current * 7.0f);
        if (value > g_frontSwitchLimit) {
            g_frontSwitchLimit = 5000.0f * SECOND;
            return true;
        }
        return false;
    }

    bool Front_AiIsSwitchAllowed(const CCircuitDef@ facDef, float armyCost, int factoryCount, float metalCurrent, bool &out assistRequired) {
        return true;
    }

    int Front_MakeSwitchInterval() {
        return 30 * SECOND;
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

        // Route T1 land constructors (bot or vehicle) to FRONT logic; others fallback
        int ctorTier = UnitHelpers::GetConstructorTier(udef);
        if (ctorTier == 1) {
            if (builder is Builder::primaryT1BotConstructor || builder is Builder::secondaryT1BotConstructor
             || builder is Builder::primaryT1VehConstructor || builder is Builder::secondaryT1VehConstructor) {
                // Use same economy snapshot style as T2: min over last 10s for incomes
                bool isEnergyFull = aiEconomyMgr.isEnergyFull;
                bool isEnergyStalling = aiEconomyMgr.isEnergyStalling;
                float metalIncome = Economy::GetMinMetalIncomeLast10s();
                float energyIncome = Economy::GetMinEnergyIncomeLast10s();
                return Front_T1Constructor_AiMakeTask(builder, defaultTask, metalIncome, energyIncome, isEnergyStalling, isEnergyFull);
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
        GenericHelpers::LogUtil("[FRONT] IncomeLimits: mi=" + metalIncome + " frame=" + ai.frame, 2);

        Front_IncomeLabLimits(metalIncome);
        Front_IncomeBuilderLimits(metalIncome);

        //Always apply map limits, regardless of how eco changes labs limits
        dictionary mapLimits = Global::Map::Config.UnitLimits;
        UnitHelpers::ApplyUnitLimits(mapLimits);
    }

    void Front_IncomeLabLimits(float metalIncome) {
        string side = Global::AISettings::Side;

        // Side-specific unit names
        string t1BotLab, t1VehLab, t1AirPlant, t2BotLab, t2VehLab, t2AirPlant;
        if (side == "armada") {
            t1BotLab = "armlab"; t1VehLab = "armvp"; t1AirPlant = "armap";
            t2BotLab = "armalab"; t2VehLab = "armavp"; t2AirPlant = "armaap";
        } else if (side == "cortex") {
            t1BotLab = "corlab"; t1VehLab = "corvp"; t1AirPlant = "corap";
            t2BotLab = "coralab"; t2VehLab = "coravp"; t2AirPlant = "coraap";
        } else {
            t1BotLab = "leglab"; t1VehLab = "legvp"; t1AirPlant = "legap";
            t2BotLab = "legalab"; t2VehLab = "legavp"; t2AirPlant = "legaap";
        }

        // Build-order prerequisites (side-specific)
        bool hasT1LandLab = (UnitDefHelpers::GetUnitDefCount(t1BotLab) + UnitDefHelpers::GetUnitDefCount(t1VehLab)) > 0;
        bool hasT1Air = UnitDefHelpers::GetUnitDefCount(t1AirPlant) > 0;
        bool hasT2LandLab = (UnitDefHelpers::GetUnitDefCount(t2BotLab) + UnitDefHelpers::GetUnitDefCount(t2VehLab)) > 0;
        bool hasT2Air = UnitDefHelpers::GetUnitDefCount(t2AirPlant) > 0;

        GenericHelpers::LogUtil("[FRONT][BUILDORDER] pre: T1Land=" + hasT1LandLab + " T1Air=" + hasT1Air + " T2Land=" + hasT2LandLab + " T2Air=" + hasT2Air + " mi=" + metalIncome, 2);

        // T1 land labs: always allowed, cap at 1
        UnitHelpers::BatchApplyUnitCaps({ t1BotLab, t1VehLab }, 1);

        // T1 air: only after T1 land lab exists
        int t1AirCap = (hasT1LandLab ? 1 : 0);
        if (t1AirCap > 0 && !g_frontLoggedT1AirCap) {
            g_frontLoggedT1AirCap = true;
            GenericHelpers::LogUtil("[FRONT][BUILDORDER] T1 air cap LIFTED to 1 (hasT1LandLab=true)", 1);
        }
        UnitHelpers::BatchApplyUnitCaps({ t1AirPlant }, t1AirCap);

        // T2 land labs: only after T1 air exists
        int t2LandCap = (hasT1Air && metalIncome >= 45.0f ? 1 : 0);
        if (t2LandCap > 0 && !g_frontLoggedT2LandCap) {
            g_frontLoggedT2LandCap = true;
            GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 land lab cap LIFTED to 1 (hasT1Air=" + hasT1Air + " mi=" + metalIncome + ")", 1);
        }
        UnitHelpers::BatchApplyUnitCaps({ t2BotLab, t2VehLab }, t2LandCap);

        // T2 air plants: 1st at MI>=100, 2nd at MI>=200
        int t2AirCap = 0;
        if (hasT2LandLab) {
            if (metalIncome >= 200.0f) t2AirCap = 2;
            else if (metalIncome >= Global::RoleSettings::Air::RequiredMetalIncomeForT2AircraftPlant) t2AirCap = 1;
        }
        if (t2AirCap > 0 && !g_frontLoggedT2AirCap) {
            g_frontLoggedT2AirCap = true;
            GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 air cap LIFTED to " + t2AirCap + " (hasT2LandLab=" + hasT2LandLab + " mi=" + metalIncome + ")", 1);
        }
        UnitHelpers::BatchApplyUnitCaps({ t2AirPlant }, t2AirCap);

        // T3 gantries: only after T2 air exists
        int t3GantryCap = (hasT2Air && metalIncome >= 250.0f ? 1 : 0);
        if (t3GantryCap > 0 && !g_frontLoggedT3GantryCap) {
            g_frontLoggedT3GantryCap = true;
            GenericHelpers::LogUtil("[FRONT][BUILDORDER] T3 gantry cap LIFTED to 1 (hasT2Air=" + hasT2Air + " mi=" + metalIncome + ")", 1);
        }
        array<string> gantries = { "armshltx", "armshltxuw", "corgant", "corgantuw", "leggant", "legapt3" };
        UnitHelpers::BatchApplyUnitCaps(gantries, t3GantryCap);

        // Nuke silo cap: 0 until forceEco gate expires and income is sufficient
        bool forceEco = (ai.frame < (20 * 60 * SECOND));
        int nukeCap = (!forceEco && metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForNuke ? Global::RoleSettings::Front::NukeLimit : 0);
        if (nukeCap > 0 && !g_frontLoggedNukeCap) {
            g_frontLoggedNukeCap = true;
            GenericHelpers::LogUtil("[FRONT][BUILDORDER] Nuke silo cap LIFTED to " + nukeCap + " (mi=" + metalIncome + ")", 1);
        }
        UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllNukeSilos(), nukeCap);
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
        AIFloat3 conLocation = u.GetPos(ai.frame);
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        GenericHelpers::LogUtil("[FRONT][T1CON] entry mi=" + metalIncome + " ei=" + energyIncome + " builder=" + u.circuitDef.GetName() + " id=" + u.id, 2);

        // Build-order: T1 air plant before T2 lab (if T1 land lab exists and no air plant yet)
        string t1AirPlantName = (unitSide == "armada" ? "armap" : unitSide == "cortex" ? "corap" : "legap");
        int t1AirPlantCount = UnitDefHelpers::GetUnitDefCount(t1AirPlantName);
        if (t1AirPlantCount <= 0 && !Factory::IsT1AirPlantBuildQueued() && metalIncome >= 15.0f && energyIncome >= 150.0f) {
            IUnitTask@ tAir = Builder::EnqueueT1AirFactory(unitSide, Factory::GetAirPlantBuildPos(), SQUARE_SIZE * 24, 600 * SECOND);
            if (tAir !is null) {
                GenericHelpers::LogUtil("[FRONT][BUILDORDER] T1 CONSTRUCTOR enqueuing T1 air plant (mi=" + metalIncome + " ei=" + energyIncome + ")", 1);
                return tAir;
            }
        }

        // Primary constructor branch (Bots)
        if (u is Builder::primaryT1BotConstructor) {
            int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
            int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());
            GenericHelpers::LogUtil("[FRONT][T1CON] primaryBot: t2LabCount=" + t2LabCount + " t1AirCount=" + t1AirPlantCount, 2);

            // Fast-track: build T2 Bot Lab if triggers met and T1 air exists (only if none queued)
            if (t2LabCount < 1 && t1AirPlantCount > 0 && !Factory::IsT2LabBuildQueued()) {
                const float incomeTrigger = Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab;
                const bool timeTriggerMet = (ai.frame >= (22 * 60 * SECOND));
                const bool incomeTriggerMet = (metalIncome >= incomeTrigger);
                bool storedMetalTriggerMet = false;
                string t2LabName = UnitHelpers::GetT2BotLabForSide(unitSide);
                CCircuitDef@ t2LabDef = ai.GetCircuitDef(t2LabName);
                if (t2LabDef !is null) {
                    storedMetalTriggerMet = (aiEconomyMgr.metal.current >= t2LabDef.costM);
                }
                GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 fast-track check: time=" + timeTriggerMet + " income=" + incomeTriggerMet + " stored=" + storedMetalTriggerMet + " mi=" + metalIncome, 2);
                if (incomeTriggerMet || timeTriggerMet || storedMetalTriggerMet) {
                    AIFloat3 anchor2 = Factory::GetT1BotLabPos();
                    IUnitTask@ t2b = Builder::EnqueueT2LabIfNeeded(unitSide, anchor2, SQUARE_SIZE * 30, SECOND * 300);
                    if (t2b !is null) {
                        GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 bot lab FAST-TRACK triggered (mi=" + metalIncome + ")", 1);
                        return t2b;
                    }
                }
            }

            // Normal T2 lab check (only if T1 air exists and none already queued)
            if (t1AirPlantCount > 0 && !Factory::IsT2LabBuildQueued()) {
                bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLab(
                    metalIncome, energyIncome,
                    aiEconomyMgr.metal.current,
                    Global::RoleSettings::Front::MinimumMetalIncomeForT2Lab,
                    Global::RoleSettings::Front::RequiredMetalCurrentForT2Lab,
                    Global::RoleSettings::Front::MinimumEnergyIncomeForT2Lab,
                    u.circuitDef, t2LabCount,
                    Global::RoleSettings::Front::MaxT2BotLabs,
                    (Factory::primaryT1BotLab !is null)
                );
                GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 normal check result=" + shouldT2Lab + " mi=" + metalIncome + " ei=" + energyIncome, 2);
                if (shouldT2Lab) {
                    GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 bot lab NORMAL triggered (mi=" + metalIncome + ")", 1);
                    AIFloat3 anchor = Factory::GetT1BotLabPos();
                    IUnitTask@ tLab = Builder::EnqueueT2LabIfNeeded(unitSide, anchor, SQUARE_SIZE * 30, SECOND * 300);
                    if (tLab !is null) return tLab;
                }
            }

            // Nano caretaker
            {
                float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                    ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage)
                    : 0.0f;
                if (EconomyHelpers::ShouldBuildT1Nano_ByReserves(
                    aiEconomyMgr.metal.current,
                    500.0f,
                    energyPercent
                )) {
                    CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                    if (targetFactory !is null) {
                        IUnitTask@ tNano = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::HIGH);
                        if (tNano !is null) return tNano;
                    }
                }
            }

            // T2 air plant: 1st at MI>=100, 2nd at MI>=200 (requires any T2 land lab - bot or vehicle)
            bool hasT2LandLab = (t2LabCount > 0) || (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs()) > 0);
            if (Factory::primaryT1AirPlant !is null && hasT2LandLab) {
                int t2AirPlantCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AircraftPlants());
                float requiredMI = (t2AirPlantCount < 1) ? Global::RoleSettings::Air::RequiredMetalIncomeForT2AircraftPlant : 200.0f;
                if (t2AirPlantCount < 2 && metalIncome >= requiredMI) {
                    AIFloat3 anchor = Factory::GetT1AirPlantPos();
                    IUnitTask@ tT2Air = Builder::EnqueueT2AirPlant(unitSide, anchor, SQUARE_SIZE * 30, 600 * SECOND);
                    if (tT2Air !is null) {
                        GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 air plant " + (t2AirPlantCount < 1 ? "1" : "2") + " queued (mi=" + metalIncome + ")", 1);
                        return tT2Air;
                    }
                }
            }

        }

        // Primary constructor branch (Vehicles)
        if (u is Builder::primaryT1VehConstructor) {
            int t2VehLabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2VehicleLabs());
            GenericHelpers::LogUtil("[FRONT][T1CON] primaryVeh: t2VehCount=" + t2VehLabCount + " t1AirCount=" + t1AirPlantCount + " mi=" + metalIncome, 2);
            if (t2VehLabCount < 1 && !Factory::IsT2VehPlantBuildQueued() && t1AirPlantCount > 0 && metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForFirstT2Lab && Builder::IsT2VehFactoryOffCooldown()) {
                GenericHelpers::LogUtil("[FRONT][BUILDORDER] T2 vehicle plant triggered (mi=" + metalIncome + ")", 1);
                IUnitTask@ tVeh2 = Builder::EnqueueT2VehiclePlant(Global::AISettings::Side, Factory::GetPreferredFactoryPos(), SQUARE_SIZE * 24, 600 * SECOND);
                if (tVeh2 !is null) return tVeh2;
            }
            return defaultTask;
        }

    return defaultTask;
    }

    IUnitTask@ Front_T2Constructor_AiMakeTask(CCircuitUnit@ u, IUnitTask@ defaultTask, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent) {
        string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
        GenericHelpers::LogUtil("[FRONT][T2CON] entry mi=" + metalIncome + " ei=" + energyIncome + " builder=" + u.circuitDef.GetName() + " id=" + u.id, 2);

        // Freelance T2 constructors just do default tasks
        if (u is Builder::freelanceT2BotConstructor) {
            return defaultTask;
        }

        const bool isPrimary = (u is Builder::primaryT2BotConstructor || u is Builder::primaryT2VehConstructor);
        const bool isSecondary = (u is Builder::secondaryT2BotConstructor);

        AIFloat3 anchor = Factory::GetT2BotLabPos();

        // Eco gating: force economy builds for the first 20 minutes
        const bool forceEco = (ai.frame < (20 * 60 * SECOND));

        if (isPrimary) {
            // Fusion Reactor
            if (EconomyHelpers::ShouldBuildFusionReactor(
                metalIncome, energyIncome,
                isEnergyLessThan90Percent,
                Global::RoleSettings::Tech::MinimumMetalIncomeForFUS,
                Global::RoleSettings::Tech::MinimumEnergyIncomeForFUS,
                Global::RoleSettings::Tech::MaxEnergyIncomeForFUS
            )) {
                GenericHelpers::LogUtil("[FRONT][T2CON] Enqueuing fusion reactor (mi=" + metalIncome + ")", 1);
                IUnitTask@ tFus2 = Builder::EnqueueFUS(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                if (tFus2 !is null) return tFus2;
            }

            // Nuke silo (late game, no rush)
            if (!forceEco) {
                int nukeTotal = EconomyHelpers::GetNukeSiloCount();
                int nukeQueued = Builder::NukeSiloQueuedCount;
                int nukeCap = Global::RoleSettings::Front::NukeLimit;
                GenericHelpers::LogUtil("[FRONT][NUKE] forceEco=" + forceEco + " nukeTotal=" + nukeTotal + " nukeQueued=" + nukeQueued + " cap=" + nukeCap + " mi=" + metalIncome + " ei=" + energyIncome, 2);
                if (nukeCap > 0 && (nukeTotal + nukeQueued) < nukeCap &&
                    metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForNuke &&
                    energyIncome >= Global::RoleSettings::Front::MinimumEnergyIncomeForNuke) {
                    IUnitTask@ tNuke = Builder::EnqueueNukeSilo(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                    if (tNuke !is null) {
                        GenericHelpers::LogUtil("[FRONT][NUKE] Enqueuing nuke silo (" + (nukeTotal + nukeQueued + 1) + "/" + nukeCap + ")", 1);
                        return tNuke;
                    }
                }
            }

            // Anti-nuke (not gated by forceEco — defensive structure for self-protection)
            {
                int antiNukeTotal = EconomyHelpers::GetAntiNukeCount();
                GenericHelpers::LogUtil("[FRONT][ANTINUKE] antiNukeTotal=" + antiNukeTotal + " min=" + Global::RoleSettings::Front::MinimumAntiNukeCount + " mi=" + metalIncome + " ei=" + energyIncome, 2);
                if (antiNukeTotal < Global::RoleSettings::Front::MinimumAntiNukeCount &&
                    metalIncome >= Global::RoleSettings::Front::MinimumMetalIncomeForAntiNuke &&
                    energyIncome >= Global::RoleSettings::Front::MinimumEnergyIncomeForAntiNuke) {
                    IUnitTask@ tAmd = Builder::EnqueueAntiNuke(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
                    if (tAmd !is null) {
                        GenericHelpers::LogUtil("[FRONT][ANTINUKE] Enqueuing anti-nuke", 1);
                        return tAmd;
                    }
                }
            }
        } 

        return defaultTask;
    }

    /******************************************************************************

    ROLE CONFIGURATION

    ******************************************************************************/

    bool Front_RoleMatch(AiRole preferredMapRole, const string &in side, const AIFloat3& in pos, const string &in defaultStartFactory) {
        GenericHelpers::LogUtil("[RoleMatch] FRONT (forced)", 2);
        return true;
    }

    void Register() {
        if (RoleConfigs::Get(AiRole::FRONT) !is null) return;
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
