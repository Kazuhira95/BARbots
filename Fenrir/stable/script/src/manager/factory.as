#include "../define.as"
#include "../unit.as"
#include "../task.as"
#include "../types/opener.as"
#include "../types/map_config.as"
#include "../global.as"
#include "../types/role_config.as"
#include "../helpers/unit_helpers.as"
#include "builder.as"

namespace Factory {

	/******************************************************************************

    VARIABLES

    ******************************************************************************/

	enum Attr {
		T1 = 0x0001, T2 = 0x0002, T3 = 0x0004, T4 = 0x0008
	}

	class SUserData {
		SUserData(int a) {
			attr = a;
		}
		SUserData() {}
		int attr = 0;
	}

	// Example of userData per UnitDef
	array<SUserData> userData(ai.GetDefCount() + 1);

	// Primary lab references are tracked by Factory manager
	CCircuitUnit@ primaryT1BotLab = null;
	CCircuitUnit@ primaryT2BotLab = null;
	CCircuitUnit@ primaryT1VehPlant = null;
	CCircuitUnit@ primaryT2VehPlant = null;
	CCircuitUnit@ primaryT1AirPlant = null;
	CCircuitUnit@ primaryT2AirPlant = null;
	CCircuitUnit@ primaryT1Shipyard = null;
	CCircuitUnit@ primaryT2Shipyard = null;
	// Hover factories (T1): land and floating variants
	CCircuitUnit@ primaryT1HoverPlant = null;      // armhp/corhp/leghp
	CCircuitUnit@ primaryFloatingHoverPlant = null; // armfhp/corfhp/legfhp
	// Seaplane platform (T2 water tech)
	CCircuitUnit@ primarySeaplanePlatform = null; // armplat/corplat (Legion uses corplat)
	CCircuitUnit@ primaryLandGantry = null;   // Experimental Gantry (land)
	CCircuitUnit@ primaryWaterGantry = null;  // Underwater Experimental Gantry

	// --- Nano per-factory tracking and caps ---
	// Max caretakers per factory type
	const int MaxNanosPerT1Factory = 5;
	const int MaxNanosPerT2Factory = 20;
	// Separate cap for T2 shipyards (naval T2 yards generally need more caretakers)
	const int MaxNanosPerT2Shipyard = 40;
	const int MaxNanosPerGantry    = 30;

	// Large sentinel used when selecting the next factory needing nanos
	const int NanoSelectionInitHigh = 1000000;

	// Track all factories by id -> handle, and each factory's nano count (id -> int)
	dictionary allFactories;      // key: string unitId -> CCircuitUnit@
	dictionary factoryNanoCounts; // key: string unitId -> int count

	// Queued build counters for key factories/energy
	int T1AirPlantQueuedCount = 0;
	int T2BotLabQueuedCount = 0;
	int T2VehPlantQueuedCount = 0;
	int T2AirPlantQueuedCount = 0;
	int T2ShipyardQueuedCount = 0;
	int FusionQueuedCount = 0;
	int AdvancedFusionQueuedCount = 0;

	string armlab  ("armlab");
	string armalab ("armalab");
	string armvp   ("armvp");
	string armavp  ("armavp");
	string armsy   ("armsy");
	string armasy  ("armasy");
	string armap   ("armap");
	string armaap  ("armaap");
	string armshltx("armshltx");
	string corlab  ("corlab");
	string coralab ("coralab");
	string corvp   ("corvp");
	string coravp  ("coravp");
	string corsy   ("corsy");
	string corasy  ("corasy");
	string corap   ("corap");
	string coraap  ("coraap");
	string corgant ("corgant");
	string leglab  ("leglab");
	string legalab ("legalab");
	string legvp   ("legvp");
	string legavp  ("legavp");
	string legsy   ("legsy"); // Correct Legion T1 shipyard id (was placeholder 'legjim')
	string legasy  ("legasy");
	string legap   ("legap");
	string legaap  ("legaap");
	string leggant ("leggant");

	/******************************************************************************

    ANGELSCRIPT HOOKS 

    ******************************************************************************/

	IUnitTask@ AiMakeTask(CCircuitUnit@ u)
	{
		IUnitTask@ t = null;

		string uname = (u is null || u.circuitDef is null) ? "null" : u.circuitDef.GetName();
		GenericHelpers::LogUtil("[FACTORY] AiMakeTask called for '" + uname + "'", 1);

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.FactoryAiMakeTaskHandler !is null) {
			GenericHelpers::LogUtil("[FACTORY] AiMakeTask delegating to role handler for '" + uname + "'", 1);
			@t = cfg.FactoryAiMakeTaskHandler(u);
		}
		else {
			GenericHelpers::LogUtil("[FACTORY] AiMakeTask using DefaultMakeTask for '" + uname + "' (cfg=" + (cfg is null ? "null" : "ok") + " handler=" + (cfg is null ? "n/a" : (cfg.FactoryAiMakeTaskHandler is null ? "null" : "ok")) + ")", 1);
			@t = aiFactoryMgr.DefaultMakeTask(u);
		}

		// Landlocked restriction: only whitelisted combat units and builders/assist allowed
		if (t !is null && Global::Map::LandLocked) {
			CCircuitDef@ buildDef = t.GetBuildDef();
			if (buildDef !is null && !IsUnitAllowedOnLandlocked(buildDef)) {
				GenericHelpers::LogUtil("[FACTORY] Landlocked: rejected '" + buildDef.GetName() + "' from '" + uname + "'", 1);
				return null;
			}
		}

		return t;
	}



	void AiTaskAdded(IUnitTask@ task)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if(cfg !is null && cfg.FactoryAiTaskAddedHandler !is null)
			cfg.FactoryAiTaskAddedHandler(task);

		// RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		// if(cfg !is null && cfg.AiTaskAddedHandler !is null)
		// 	cfg.AiTaskAddedHandler(task);
	}

	void AiTaskRemoved(IUnitTask@ task, bool done)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if(cfg !is null && cfg.FactoryAiTaskRemovedHandler !is null)
			cfg.FactoryAiTaskRemovedHandler(task, done);
		// RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		// if(cfg !is null && cfg.AiTaskRemovedHandler !is null)
		// 	cfg.AiTaskRemovedHandler(task, done);
	}

	// CCircuitUnit@ energizer1 = null;
	// CCircuitUnit@ energizer2 = null;
	
	void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (unit is null) {
			GenericHelpers::LogUtil("[FACTORY] AiUnitAdded: unit=<null>", 2);
			return;
		}
		const CCircuitDef@ cdef = unit.circuitDef;
        // Log basic unitdef info on add
        if (cdef is null) {
            GenericHelpers::LogUtil("[TECH] FactoryAiUnitAdded: cdef=<null> id=" + unit.id, 2);
        } else {
            string uname = cdef.GetName();

            string usageStr = "OTHER";
            switch (usage) {
                case Unit::UseAs::BUILDER: usageStr = "BUILDER"; break;
                case Unit::UseAs::FACTORY: usageStr = "FACTORY"; break;
                default: break;
            }

            bool isComm = cdef.IsRoleAny(Unit::Role::COMM.mask);
            int ctorTier = UnitHelpers::GetConstructorTier(cdef);

            GenericHelpers::LogUtil(
                "[TECH] FactoryAiUnitAdded: id=" + unit.id +
                " name=" + uname +
                " usage=" + usageStr +
                " ctorTier=" + ctorTier +
                " isCommander=" + (isComm ? "true" : "false"),
                2
            );
        }


		// Track primary lab references centrally
		// Minimal guard: only assign when this unit is registered as a FACTORY
		if (usage == Unit::UseAs::FACTORY && cdef !is null && UnitHelpers::IsT1BotLab(cdef.GetName()) && Factory::primaryT1BotLab is null) {
			@Factory::primaryT1BotLab = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryT1BotLab set to id=" + unit.id, 2);
		}

		if (cdef !is null && UnitHelpers::IsT2BotLab(cdef.GetName()) && Factory::primaryT2BotLab is null) {
			@Factory::primaryT2BotLab = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryT2BotLab set to id=" + unit.id, 2);
		}

		// Vehicle labs
		if (cdef !is null && UnitHelpers::IsT1VehicleLab(cdef.GetName()) && Factory::primaryT1VehPlant is null) {
			@Factory::primaryT1VehPlant = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryT1VehPlant set to id=" + unit.id, 2);
		}

		if (cdef !is null && UnitHelpers::IsT2VehicleLab(cdef.GetName()) && Factory::primaryT2VehPlant is null) {
			@Factory::primaryT2VehPlant = unit;
			if (T2VehPlantQueuedCount > 0) { T2VehPlantQueuedCount--; }
			GenericHelpers::LogUtil("[FACTORY] primaryT2VehPlant set to id=" + unit.id, 2);
		}

		// Aircraft plants
		if (cdef !is null && UnitHelpers::IsT1AircraftPlant(cdef.GetName()) && Factory::primaryT1AirPlant is null) {
			@Factory::primaryT1AirPlant = unit;
			if (T1AirPlantQueuedCount > 0) { T1AirPlantQueuedCount--; }
			GenericHelpers::LogUtil("[FACTORY] primaryT1AirPlant set to id=" + unit.id, 2);
		}

		if (cdef !is null && UnitHelpers::IsT2AircraftPlant(cdef.GetName()) && Factory::primaryT2AirPlant is null) {
			@Factory::primaryT2AirPlant = unit;
			if (T2AirPlantQueuedCount > 0) { T2AirPlantQueuedCount--; }
			GenericHelpers::LogUtil("[FACTORY] primaryT2AirPlant set to id=" + unit.id, 2);
		}

		// Shipyards
		if (cdef !is null && UnitHelpers::IsT1Shipyard(cdef.GetName()) && Factory::primaryT1Shipyard is null) {
			@Factory::primaryT1Shipyard = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryT1Shipyard set to id=" + unit.id, 2);
		}

		if (cdef !is null && UnitHelpers::IsT2Shipyard(cdef.GetName()) && Factory::primaryT2Shipyard is null) {
			@Factory::primaryT2Shipyard = unit;
			if (T2ShipyardQueuedCount > 0) { T2ShipyardQueuedCount--; }
			GenericHelpers::LogUtil("[FACTORY] primaryT2Shipyard set to id=" + unit.id, 2);
		}

		// Hover plants (T1 land and floating variants)
		if (cdef !is null && UnitHelpers::IsT1HoverPlant(cdef.GetName()) && Factory::primaryT1HoverPlant is null) {
			@Factory::primaryT1HoverPlant = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryT1HoverPlant set to id=" + unit.id, 2);
		}

		if (cdef !is null && UnitHelpers::IsFloatingHoverPlant(cdef.GetName()) && Factory::primaryFloatingHoverPlant is null) {
			@Factory::primaryFloatingHoverPlant = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryFloatingHoverPlant set to id=" + unit.id, 2);
		}

		// Seaplane platform
		if (cdef !is null && UnitHelpers::IsSeaplanePlatform(cdef.GetName()) && Factory::primarySeaplanePlatform is null) {
			@Factory::primarySeaplanePlatform = unit;
			GenericHelpers::LogUtil("[FACTORY] primarySeaplanePlatform set to id=" + unit.id, 2);
		}

		// Track all factories and initialize nano count when a factory is added
		if (usage == Unit::UseAs::FACTORY && cdef !is null) {
			string key = "" + unit.id;
			// Register the factory handle
			allFactories.set(key, @unit);
			// Ensure a nano count entry exists (0 if new)
			int tmp = 0;
			if (!factoryNanoCounts.get(key, tmp)) {
				factoryNanoCounts.set(key, 0);
			}
			GenericHelpers::LogUtil("[FACTORY] Tracked factory id=" + unit.id + " name=" + cdef.GetName(), 3);
		}

		// Experimental gantries (land & water)
		if (cdef !is null && UnitHelpers::IsLandGantry(cdef.GetName()) && Factory::primaryLandGantry is null) {
			@Factory::primaryLandGantry = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryLandGantry set to id=" + unit.id, 2);
		}
		if (cdef !is null && UnitHelpers::IsWaterGantry(cdef.GetName()) && Factory::primaryWaterGantry is null) {
			@Factory::primaryWaterGantry = unit;
			GenericHelpers::LogUtil("[FACTORY] primaryWaterGantry set to id=" + unit.id, 2);
		}

		// Decrement T2 Bot Lab queued if a T2 bot lab completes registration
		if (cdef !is null && UnitHelpers::IsT2BotLab(cdef.GetName())) {
			if (T2BotLabQueuedCount > 0) { T2BotLabQueuedCount--; }
		}
		// Energy builds: decrement queued counts if fusions arrive here
		if (cdef !is null) {
			string n = cdef.GetName();
			array<string> f = UnitHelpers::GetAllFusionReactors();
			for (uint i = 0; i < f.length(); ++i) { if (f[i] == n) { if (FusionQueuedCount > 0) FusionQueuedCount--; break; } }
			array<string> af = UnitHelpers::GetAllAdvancedFusionReactors();
			for (uint j = 0; j < af.length(); ++j) { if (af[j] == n) { if (AdvancedFusionQueuedCount > 0) AdvancedFusionQueuedCount--; break; } }
		}
		// const CCircuitDef@ cdef = unit.circuitDef;

		// if (usage == Unit::UseAs::FACTORY){
		// 	//GenericHelpers::LogUtil("FACTORY::AiUnitAdded:" + unit.GetId(), 2);

		// 	if (userData[cdef.id].attr & Attr::T3 != 0) {
		// 		// if (ai.teamId != ai.GetLeadTeamId()) then this change affects only target selection,
		// 		// while threatmap still counts "ignored" here units.
		// 		array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav"};
		// 		for (uint i = 0; i < spam.length(); ++i)
		// 			ai.GetCircuitDef(spam[i]).SetIgnore(true);
		// 	}
			
		// 	const array<Opener::SO>@ opener = Opener::GetOpener(cdef);
		// 	if (opener is null)
		// 		return;

		// 	const AIFloat3 pos = unit.GetPos(ai.frame);
		// 	for (uint i = 0, icount = opener.length(); i < icount; ++i) {
		// 		CCircuitDef@ buildDef = aiFactoryMgr.GetRoleDef(cdef, opener[i].role);
		// 		if ((buildDef is null) || !buildDef.IsAvailable(ai.frame))
		// 			continue;

		// 		Task::Priority priority;
		// 		Task::RecruitType recruit;
		// 		if (opener[i].role == Unit::Role::BUILDER.type) {
		// 			priority = Task::Priority::NORMAL;
		// 			recruit  = Task::RecruitType::BUILDPOWER;
		// 		} else {
		// 			priority = Task::Priority::HIGH;
		// 			recruit  = Task::RecruitType::FIREPOWER;
		// 		}
		// 		for (uint j = 0, jcount = opener[i].count; j < jcount; ++j)
		// 			aiFactoryMgr.Enqueue(TaskS::Recruit(recruit, priority, buildDef, pos, 64.f));
		// 	}
		// }

		// if (usage == Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask)) {
			
		// 	if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
		// 		return;

		// 	// constructor with BASE attribute is assigned to tasks near base
		// 	if (cdef.costM < 200.f) {
		// 		if (energizer1 is null
		// 			&& (uint(cdef.count) > aiMilitaryMgr.GetGuardTaskNum() || cdef.IsAbleToFly()))
		// 		{
		// 			@energizer1 = unit;
		// 			unit.AddAttribute(Unit::Attr::BASE.type);
		// 		}
		// 	} else {
		// 		if (energizer2 is null) {
		// 			@energizer2 = unit;
		// 			unit.AddAttribute(Unit::Attr::BASE.type);
		// 		}
		// 	}
		// }

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.FactoryAiUnitAdded !is null) {
			cfg.FactoryAiUnitAdded(unit, usage);
		}
		
		
	}

	void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		if (unit is null) 
            return;
		GenericHelpers::LogUtil("Enter FactoryAiUnitRemoved", 4);
		// Clear lab references when a lab dies
		if (Factory::primaryT1BotLab is unit){ @Factory::primaryT1BotLab = null; }
		if (Factory::primaryT2BotLab is unit){ @Factory::primaryT2BotLab = null; }
		if (Factory::primaryT1VehPlant is unit){ @Factory::primaryT1VehPlant = null; }
		if (Factory::primaryT2VehPlant is unit){ @Factory::primaryT2VehPlant = null; }
		if (Factory::primaryT1AirPlant is unit){ @Factory::primaryT1AirPlant = null; }
		if (Factory::primaryT2AirPlant is unit){ @Factory::primaryT2AirPlant = null; }
		if (Factory::primaryT1Shipyard is unit){ @Factory::primaryT1Shipyard = null; }
		if (Factory::primaryT2Shipyard is unit){ @Factory::primaryT2Shipyard = null; }
		if (Factory::primaryT1HoverPlant is unit){ @Factory::primaryT1HoverPlant = null; }
		if (Factory::primaryFloatingHoverPlant is unit){ @Factory::primaryFloatingHoverPlant = null; }
		if (Factory::primarySeaplanePlatform is unit){ @Factory::primarySeaplanePlatform = null; }
		if (Factory::primaryLandGantry is unit){ @Factory::primaryLandGantry = null; }
		if (Factory::primaryWaterGantry is unit){ @Factory::primaryWaterGantry = null; }
		   
		// Remove factory from tracking maps if it was a factory
		if (usage == Unit::UseAs::FACTORY) {
			string key = "" + unit.id;
			allFactories.delete(key);
			factoryNanoCounts.delete(key);
			GenericHelpers::LogUtil("[FACTORY] Untracked factory id=" + unit.id, 3);
		}
		
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.FactoryAiUnitRemoved !is null) {
			cfg.FactoryAiUnitRemoved(unit, usage);
		}
	}

	void AiLoad(IStream& istream)
	{
	}

	void AiSave(OStream& ostream)
	{
	}

	/*
	* New factory switch condition; switch event is also based on eco + caretakers.
	*/
	bool AiIsSwitchTime(int lastSwitchFrame)
	{
		bool isSwitchTime = false;

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		
		// Delegate to role handler if present; otherwise compute with default formula
		if(cfg !is null && cfg.AiIsSwitchTimeHandler !is null)
			isSwitchTime = cfg.AiIsSwitchTimeHandler(lastSwitchFrame);

		GenericHelpers::LogUtil("Factory switch due (role=" + Global::AISettings::Role + ")", 2); 
		
		return isSwitchTime;
	}

	bool AiIsSwitchAllowed(CCircuitDef@ facDef)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		
		bool assistRequired = false;
		bool ok;

		if (cfg !is null && cfg.AiIsSwitchAllowedHandler !is null) {
			// Compute inputs for decision
			const float armyCost = aiMilitaryMgr.armyCost;
			const int factoryCount = aiFactoryMgr.GetFactoryCount();
			const float metalCurrent = aiEconomyMgr.metal.current;
			ok = cfg.AiIsSwitchAllowedHandler(facDef, armyCost, factoryCount, metalCurrent, assistRequired);
		} 

		// Reflect assist decision into managers
		//Economy::isSwitchAssist = assistRequired;
		aiFactoryMgr.isAssistRequired = assistRequired;
		
		GenericHelpers::LogUtil("Factory switch allowed=" + ok + " assist=" + assistRequired + " fac=" + facDef.GetName(), 2); 
		
		return ok;
	}

	// Queued-state predicates (counts > 0)
	bool IsT1AirPlantBuildQueued() { return T1AirPlantQueuedCount > 0; }
	bool IsT2LabBuildQueued()      { return T2BotLabQueuedCount > 0; }
	bool IsT2VehPlantBuildQueued() { return T2VehPlantQueuedCount > 0; }
	bool IsT2AirPlantBuildQueued() { return T2AirPlantQueuedCount > 0; }
	bool IsT2ShipyardBuildQueued() { return T2ShipyardQueuedCount > 0; }

	/* --- Utils --- */

	// Removed MakeSwitchLimit; each role config owns MakeSwitchInterval

	// Helper: return commander position if present, else a sentinel AIFloat3(-1,0,0)
	AIFloat3 _CommanderPosOrSentinel()
	{
		CCircuitUnit@ com = Builder::GetCommander();
		if (com is null) {
			GenericHelpers::LogUtil("[FACTORY] Commander is null; returning sentinel position (-1,0,0)", 4);
			return AIFloat3(-1.0f, 0.0f, 0.0f);
		}
		return com.GetPos(ai.frame);
	}

	// Position getters: return lab position or commander position when absent (fallback to sentinel if no commander)
	AIFloat3 GetT1BotLabPos()
	{
		return (Factory::primaryT1BotLab is null) ? _CommanderPosOrSentinel() : Factory::primaryT1BotLab.GetPos(ai.frame);
	}

	AIFloat3 GetT2BotLabPos()
	{
		return (Factory::primaryT2BotLab is null) ? _CommanderPosOrSentinel() : Factory::primaryT2BotLab.GetPos(ai.frame);
	}



	AIFloat3 GetT1VehPlantPos()
	{
		return (Factory::primaryT1VehPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryT1VehPlant.GetPos(ai.frame);
	}

	AIFloat3 GetT2VehPlantPos()
	{
		return (Factory::primaryT2VehPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryT2VehPlant.GetPos(ai.frame);
	}

	AIFloat3 GetT1AirPlantPos()
	{
		return (Factory::primaryT1AirPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryT1AirPlant.GetPos(ai.frame);
	}

	AIFloat3 GetT2AirPlantPos()
	{
		return (Factory::primaryT2AirPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryT2AirPlant.GetPos(ai.frame);
	}

	AIFloat3 GetT1ShipyardPos()
	{
		return (Factory::primaryT1Shipyard is null) ? _CommanderPosOrSentinel() : Factory::primaryT1Shipyard.GetPos(ai.frame);
	}

	AIFloat3 GetT2ShipyardPos()
	{
		return (Factory::primaryT2Shipyard is null) ? _CommanderPosOrSentinel() : Factory::primaryT2Shipyard.GetPos(ai.frame);
	}

	AIFloat3 GetT1HoverPlantPos()
	{
		return (Factory::primaryT1HoverPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryT1HoverPlant.GetPos(ai.frame);
	}

	AIFloat3 GetFloatingHoverPlantPos()
	{
		return (Factory::primaryFloatingHoverPlant is null) ? _CommanderPosOrSentinel() : Factory::primaryFloatingHoverPlant.GetPos(ai.frame);
	}

	AIFloat3 GetSeaplanePlatformPos()
	{
		return (Factory::primarySeaplanePlatform is null) ? _CommanderPosOrSentinel() : Factory::primarySeaplanePlatform.GetPos(ai.frame);
	}

	AIFloat3 GetLandGantryPos()
	{
		return (Factory::primaryLandGantry is null) ? _CommanderPosOrSentinel() : Factory::primaryLandGantry.GetPos(ai.frame);
	}

	AIFloat3 GetWaterGantryPos()
	{
		return (Factory::primaryWaterGantry is null) ? _CommanderPosOrSentinel() : Factory::primaryWaterGantry.GetPos(ai.frame);
	}

	// Master: return the first available factory position in priority order.
	// Priority: T2 Air -> T2 Bot -> T2 Vehicle -> T2 Ship -> T1 Air -> T1 Bot -> T1 Vehicle -> T1 Ship.
	// Fallback: commander position; if no commander, sentinel AIFloat3(-1,0,0).
	// Return the preferred factory unit itself using the same priority order.
	CCircuitUnit@ GetPreferredFactory()
	{
		// Always prefer gantries if available
		if (Factory::primaryLandGantry  !is null) return Factory::primaryLandGantry;
		if (Factory::primaryWaterGantry !is null) return Factory::primaryWaterGantry;

		// T2 labs first
		if (Factory::primaryT2Shipyard !is null) return Factory::primaryT2Shipyard;
		if (Factory::primaryT2AirPlant !is null) return Factory::primaryT2AirPlant;
		if (Factory::primaryT2VehPlant !is null) return Factory::primaryT2VehPlant;
		if (Factory::primaryT2BotLab   !is null) return Factory::primaryT2BotLab;

		// Prefer seaplane platform ahead of hover plants for sea-biased expansions
		if (Factory::primarySeaplanePlatform !is null) return Factory::primarySeaplanePlatform;

		// Hover plants next
		if (Factory::primaryFloatingHoverPlant !is null) return Factory::primaryFloatingHoverPlant;
		if (Factory::primaryT1HoverPlant !is null) return Factory::primaryT1HoverPlant;

		// T1 labs
		if (Factory::primaryT1AirPlant !is null) return Factory::primaryT1AirPlant;
		if (Factory::primaryT1BotLab   !is null) return Factory::primaryT1BotLab;
		if (Factory::primaryT1VehPlant !is null) return Factory::primaryT1VehPlant;
		if (Factory::primaryT1Shipyard !is null) return Factory::primaryT1Shipyard;

		return null;
	}

	// Overload: choose preferred factory anchor given a default fallback position
	AIFloat3 GetPreferredFactoryPos(const AIFloat3 &in defaultPos)
	{
		CCircuitUnit@ preferred = GetPreferredFactory();
		return (preferred is null) ? defaultPos : preferred.GetPos(ai.frame);
	}

	// Compatibility: no-arg version forwards commander/sentinel default
	AIFloat3 GetPreferredFactoryPos()
	{
		return GetPreferredFactoryPos(_CommanderPosOrSentinel());
	}

	// Returns a build position suitable for air plants, perpendicular to the base-to-factory direction
	// so the air plant cluster is separated from land factories to avoid path blocking.
	AIFloat3 GetAirPlantBuildPos()
	{
		AIFloat3 basePos = GetPreferredFactoryPos();
		AIFloat3 comPos = _CommanderPosOrSentinel();
		float dx = basePos.x - comPos.x;
		float dz = basePos.z - comPos.z;
		float perpX = -dz;
		float perpZ = dx;
		float len = sqrt(perpX * perpX + perpZ * perpZ);
		if (len < 1.0f) {
			return AIFloat3(basePos.x + SQUARE_SIZE * 30, 0, basePos.z);
		}
		return AIFloat3(basePos.x + perpX / len * SQUARE_SIZE * 35, 0, basePos.z + perpZ / len * SQUARE_SIZE * 35);
	}

	// Returns a build position for the gantry, offset far from the base center so the
	// largest T3 units (7x7 footprint) can exit without being blocked by the gantry's
	// clustered nanos or other base structures.
	// Clearance needed: unit half-extent (7/2=3.5) + gantry half-extent (~2.5) + pathing buffer (~2) ≈ 8 squares.
	AIFloat3 GetGantryBuildPos()
	{
		AIFloat3 basePos = GetPreferredFactoryPos();
		AIFloat3 comPos = _CommanderPosOrSentinel();
		float dx = basePos.x - comPos.x;
		float dz = basePos.z - comPos.z;
		float len = sqrt(dx * dx + dz * dz);
		if (len < 1.0f) {
			return AIFloat3(basePos.x + SQUARE_SIZE * 60, 0, basePos.z);
		}
		return AIFloat3(basePos.x + dx / len * SQUARE_SIZE * 90, 0, basePos.z + dz / len * SQUARE_SIZE * 90);
	}

	// --- Nano helpers ---
	// Determine the nano capacity for a given factory def
	int _GetNanoCapacityForFactoryDef(const CCircuitDef@ d)
	{
		if (d is null) return 0;
		string n = d.GetName();
		if (UnitHelpers::IsLandGantry(n) || UnitHelpers::IsWaterGantry(n)) return MaxNanosPerGantry;
		// T2 classes with special-case for shipyards
		if (UnitHelpers::IsT2Shipyard(n)) {
			return MaxNanosPerT2Shipyard;
		}
		if (UnitHelpers::IsT2BotLab(n) || UnitHelpers::IsT2VehicleLab(n) || UnitHelpers::IsT2AircraftPlant(n) || UnitHelpers::IsSeaplanePlatform(n)) {
			return MaxNanosPerT2Factory;
		}
		// T1 classes (bot/veh/air/ship/hover)
		return MaxNanosPerT1Factory;
	}

	int _GetNanoCount(CCircuitUnit@ u)
	{
		if (u is null) return 0;
		string key = "" + u.id;
		int cnt = 0;
		factoryNanoCounts.get(key, cnt);
		return cnt;
	}

	void _SetNanoCount(CCircuitUnit@ u, int cnt)
	{
		if (u is null) return;
		string key = "" + u.id;
		factoryNanoCounts.set(key, cnt);
	}

	// Choose a factory that still needs nanos by priority: Gantry > T2 > T1
	CCircuitUnit@ SelectFactoryNeedingNano()
	{
		CCircuitUnit@ best = null;
		int bestCount = NanoSelectionInitHigh;

		array<string>@ keys = allFactories.getKeys();
		if (keys is null) return null;

		// Helper lambda-like via local function objects is not supported; do two passes per priority bucket
		// Pass 1: Gantries
		for (uint i = 0; i < keys.length(); ++i) {
			CCircuitUnit@ f = null; if (!allFactories.get(keys[i], @f) || f is null) continue;
			const CCircuitDef@ d = f.circuitDef; if (d is null) continue;
			string n = d.GetName();
			bool isGantry = UnitHelpers::IsLandGantry(n) || UnitHelpers::IsWaterGantry(n);
			if (!isGantry) continue;
			int cap = _GetNanoCapacityForFactoryDef(d);
			int cur = _GetNanoCount(f);
			if (cur < cap && cur < bestCount) { @best = f; bestCount = cur; }
		}
		if (best !is null) return best;

		// Pass 2: T2
		for (uint i = 0; i < keys.length(); ++i) {
			CCircuitUnit@ f = null; if (!allFactories.get(keys[i], @f) || f is null) continue;
			const CCircuitDef@ d = f.circuitDef; if (d is null) continue;
			string n = d.GetName();
			bool isT2 = (UnitHelpers::IsT2BotLab(n) || UnitHelpers::IsT2VehicleLab(n) || UnitHelpers::IsT2AircraftPlant(n) || UnitHelpers::IsT2Shipyard(n) || UnitHelpers::IsSeaplanePlatform(n));
			if (!isT2) continue;
			int cap = _GetNanoCapacityForFactoryDef(d);
			int cur = _GetNanoCount(f);
			if (cur < cap && cur < bestCount) { @best = f; bestCount = cur; }
		}
		if (best !is null) return best;

		// Pass 3: T1 and others
		for (uint i = 0; i < keys.length(); ++i) {
			CCircuitUnit@ f = null; if (!allFactories.get(keys[i], @f) || f is null) continue;
			const CCircuitDef@ d = f.circuitDef; if (d is null) continue;
			int cap = _GetNanoCapacityForFactoryDef(d);
			int cur = _GetNanoCount(f);
			if (cur < cap && cur < bestCount) { @best = f; bestCount = cur; }
		}

		return best;
	}

	// Queue a nano for a specific factory; increments its nano count on success
	IUnitTask@ EnqueueNanoForFactory(CCircuitUnit@ factoryUnit, Task::Priority prio = Task::Priority::NORMAL)
	{
		if (factoryUnit is null || factoryUnit.circuitDef is null) return null;
		const CCircuitDef@ d = factoryUnit.circuitDef;
		int cap = _GetNanoCapacityForFactoryDef(d);
		int cur = _GetNanoCount(factoryUnit);
		if (cur >= cap) {
			GenericHelpers::LogUtil("[FACTORY] EnqueueNanoForFactory: cap reached for id=" + factoryUnit.id + " cap=" + cap + " cur=" + cur, 3);
			return null;
		}
		string name = d.GetName();
		string side = UnitHelpers::GetSideForUnitName(name);
		AIFloat3 pos = factoryUnit.GetPos(ai.frame);
		// Choose naval vs land caretaker based on factory terrain (covers shipyards, seaplane, floating hover, amphib complexes, water gantry)
		bool isWaterFactory = UnitHelpers::FactoryIsWater(name);
		IUnitTask@ t = null;
		if (isWaterFactory) {
			@t = Builder::EnqueueT1NavalNano(side, pos, /*shake*/ SQUARE_SIZE * 24, /*timeout*/ 300 * SECOND);
		} else {
			@t = Builder::EnqueueT1Nano(side, pos, /*shake*/ SQUARE_SIZE * 24, /*timeout*/ 300 * SECOND, prio);
		}
		if (t !is null) {
			_SetNanoCount(factoryUnit, cur + 1);
			GenericHelpers::LogUtil("[FACTORY] Enqueued " + (isWaterFactory ? "naval " : "") + "nano for id=" + factoryUnit.id + " name=" + name + " newCount=" + (cur + 1) + "/" + cap, 2);
		}
		return t;
	}

	// Enqueue a batch of signature experimental units from a gantry based on side
	// Returns the last enqueued task or null if unavailable
	IUnitTask@ EnqueueGantrySignatureBatch(CCircuitUnit@ gantry, const string &in side, int count = 5, Task::Priority prio = Task::Priority::HIGH)
	{
		if (gantry is null) return null;
		const CCircuitDef@ facDef = gantry.circuitDef; if (facDef is null) return null;
		string heavyName = UnitHelpers::GetGantrySignatureUnitForSide(side);
		if (heavyName.length() == 0) {
			GenericHelpers::LogUtil("[FACTORY] Gantry signature unit unresolved for side='" + side + "'", 2);
			return null;
		}

		// Build a small fallback list per side to improve robustness when the primary is capped or unavailable
		array<string> candidates;
		candidates.insertLast(heavyName);
		// Prefer amphibious options if this is a water gantry
		// bool waterFac = UnitHelpers::FactoryIsWater(facDef.GetName());
		// if (side == "armada") {
		// 	// Primary: Bantha; Fallbacks: Razorback (armraz), Lunkhead (armlun) which is amphibious/hover
		// 	// candidates.insertLast("armraz");
		// 	// candidates.insertLast("armlun");
		// 	if (waterFac) {
		// 		// Ensure amphibious candidate is early in list for water gantry
		// 		int idx = candidates.find("armlun");
		// 		if (idx >= 0) candidates.removeAt(uint(idx));
		// 		candidates.insertAt(1, "armlun");
		// 	}
		// } else if (side == "cortex") {
		// 	// Primary: Juggernaut (corkorg); Fallbacks: Shiva (corshiva, amphibious), Karganeth (corkarg)
		// 	// candidates.insertLast("corshiva");
		// 	// candidates.insertLast("corkarg");
		// 	if (waterFac) {
		// 		int idx2 = candidates.find("corshiva");
		// 		if (idx2 >= 0) candidates.removeAt(uint(idx2));
		// 		candidates.insertAt(1, "corshiva");
		// 	}
		// } else if (side == "legion") {
		// 	// Primary: Sol Invictus; Fallback: Leg Pede (legpede)
		// 	candidates.insertLast("legpede");
		// }

		CCircuitDef@ heavyDef = null;
		string chosen = "";
		for (uint i = 0; i < candidates.length(); ++i) {
			string name = candidates[i];
			@heavyDef = ai.GetCircuitDef(name);
			if (heavyDef is null) {
				GenericHelpers::LogUtil("[FACTORY] Gantry candidate missing def: '" + name + "'", 3);
				continue;
			}
			if (!heavyDef.IsAvailable(ai.frame)) {
				GenericHelpers::LogUtil("[FACTORY] Gantry candidate not available now: '" + name + "'", 3);
				continue;
			}
			chosen = name;
			break;
		}
		if (chosen.length() == 0 || heavyDef is null) {
			GenericHelpers::LogUtil("[FACTORY] Gantry signature selection failed for side='" + side + "' (all candidates unavailable)", 2);
			return null;
		}
		const AIFloat3 pos = gantry.GetPos(ai.frame);
		IUnitTask@ last = null;
		int n = (count < 1 ? 1 : count);
		for (int i = 0; i < n; ++i) {
			@last = aiFactoryMgr.Enqueue(
				TaskS::Recruit(Task::RecruitType::FIREPOWER, prio, heavyDef, pos, 64.f)
			);
		}
		GenericHelpers::LogUtil("[FACTORY] Gantry enqueued x" + n + " '" + chosen + "' from " + facDef.GetName(), 2);
		return last;
	}



	// --- Landlocked unit whitelist ---
	// On landlocked maps, only builders/assist and the listed combat units may be produced.

	bool _IsUnitNameAllowedOnLandlocked(const string &in name)
	{
		// Legion
		if (name == "legamphtank") return true;
		if (name == "legamph")     return true;
		if (name == "legehovertank") return true;
		if (name == "legjav")      return true;
		if (name == "legeheatraymech") return true;
		// Armada
		if (name == "armvader")       return true;
		if (name == "armamph")        return true;
		if (name == "armpincer")      return true;
		if (name == "armcroc")        return true;
		if (name == "armlun")         return true;
		if (name == "armmar")         return true;
		if (name == "armassimilator") return true;
		if (name == "armmeatball")    return true;
		if (name == "armbanth")       return true;
		// Cortex
		if (name == "corroach")  return true;
		if (name == "corsktl")   return true;
		if (name == "corgarp")   return true;
		if (name == "coramph")   return true;
		if (name == "corparrow") return true;
		if (name == "corsala")   return true;
		if (name == "corsok")    return true;
		if (name == "corves")    return true;
		if (name == "corshiva")  return true;
		if (name == "corkorg")   return true;

		return false;
	}

	bool IsUnitAllowedOnLandlocked(const CCircuitDef@ d)
	{
		if (d is null) return false;
		// Builders, T2 builders, support (nanos/assist), and commanders always allowed
		if (d.IsRoleAny(Unit::Role::BUILDER.mask))  return true;
		if (d.IsRoleAny(Unit::Role::BUILDER2.mask)) return true;
		if (d.IsRoleAny(Unit::Role::SUPPORT.mask))  return true;
		if (d.IsRoleAny(Unit::Role::COMM.mask))     return true;
		// Combat units: only whitelisted ones
		return _IsUnitNameAllowedOnLandlocked(d.GetName());
	}

}  // namespace Factory