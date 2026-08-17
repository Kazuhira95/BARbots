#include "../../unit.as"
#include "../../define.as"
#include "../../task.as"


namespace Builder {

int tech1AirCount = 0;
int tech2AirCount = 0;
CCircuitUnit@ energizer1 = null;
CCircuitUnit@ energizer2 = null;

const int MAX_TECH1_AIR = 2;
const int MAX_TECH2_AIR = 2;
int tech1WaterCount = 0;
int tech2WaterCount = 0;
const int MAX_TECH1_WATER = 2;
const int MAX_TECH2_WATER = 2;

bool IsWaterBuilder(const string& in name)
{
	return name == "armcs" || name == "armacsub" || name == "armbeaver" || name == "armcsa"
		|| name == "corcs" || name == "coracsub" || name == "cormuskrat" || name == "corcsa"
		|| name == "legnavyconship" || name == "leganavyconsub" || name == "legotter" || name == "legspcon";
}

IUnitTask@ AiMakeTask(CCircuitUnit@ unit)
{
	return aiBuilderMgr.DefaultMakeTask(unit);
}

void AiTaskAdded(IUnitTask@ task)
{
}

void AiTaskRemoved(IUnitTask@ task, bool done)
{
}

void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
{
	const CCircuitDef@ cdef = unit.circuitDef;
	if (usage != Unit::UseAs::BUILDER || cdef.IsRoleAny(Unit::Role::COMM.mask))
		return;

	// Water-majority map with land start: water builders > air > ground
	if (Factory::waterFactoryCount > 0 && !Factory::startedOnWater) {
		if (IsWaterBuilder(cdef.GetName())) {
			if (cdef.costM < 210.f && tech1WaterCount < MAX_TECH1_WATER) {
				tech1WaterCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			} else if (cdef.costM >= 210.f && tech2WaterCount < MAX_TECH2_WATER) {
				tech2WaterCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
			return;
		}
		if (cdef.IsAbleToFly()) {
			if (cdef.costM < 200.f && tech1AirCount < MAX_TECH1_AIR) {
				tech1AirCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			} else if (cdef.costM >= 200.f && tech2AirCount < MAX_TECH2_AIR) {
				tech2AirCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
			return;
		}
	}

	// When air factories exist, reserve up to 2 Tech1 and 2 Tech2 air builders for base tasks
	if (Factory::airFactoryCount > 0) {
		if (cdef.IsAbleToFly()) {
			if (cdef.costM < 200.f && tech1AirCount < MAX_TECH1_AIR) {
				tech1AirCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			} else if (cdef.costM >= 200.f && tech2AirCount < MAX_TECH2_AIR) {
				tech2AirCount++;
				unit.AddAttribute(Unit::Attr::BASE.type);
			}
			return;
		}
	}

	// Ground builder with BASE attribute is assigned to tasks near base
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

void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
{
	const CCircuitDef@ cdef = unit.circuitDef;
	if (cdef !is null) {
		if (IsWaterBuilder(cdef.GetName())) {
			if (cdef.costM < 210.f && tech1WaterCount > 0)
				tech1WaterCount--;
			else if (cdef.costM >= 210.f && tech2WaterCount > 0)
				tech2WaterCount--;
			return;
		}
		if (cdef.IsAbleToFly()) {
			if (cdef.costM < 200.f && tech1AirCount > 0)
				tech1AirCount--;
			else if (cdef.costM >= 200.f && tech2AirCount > 0)
				tech2AirCount--;
			return;
		}
	}
	if (energizer1 is unit)
		@energizer1 = null;
	else if (energizer2 is unit)
		@energizer2 = null;
}

void AiLoad(IStream& istream)
{
	Id e1id = -1, e2id = -1;
	istream >> e1id >> e2id >> tech1AirCount >> tech2AirCount >> tech1WaterCount >> tech2WaterCount;
	@energizer1 = ai.GetTeamUnit(e1id);
	@energizer2 = ai.GetTeamUnit(e2id);
	if (energizer1 !is null)
		energizer1.AddAttribute(Unit::Attr::BASE.type);
	if (energizer2 !is null)
		energizer2.AddAttribute(Unit::Attr::BASE.type);
}

void AiSave(OStream& ostream)
{
	ostream << Id(energizer1 !is null ? energizer1.id : -1)
			<< Id(energizer2 !is null ? energizer2.id : -1)
			<< tech1AirCount << tech2AirCount << tech1WaterCount << tech2WaterCount;
}

/* --- Nano shake helpers --- */

string GetSideForUnitName(const string& in unitName)
{
	if (unitName.length() >= 3) {
		string p = unitName.substr(0, 3);
		if (p == "arm") return "armada";
		if (p == "cor") return "cortex";
		if (p == "leg") return "legion";
	}
	return "armada";
}

string GetT1NanoNameForSide(const string& in side)
{
	if (side == "armada") return "armnanotc";
	if (side == "cortex") return "cornanotc";
	if (side == "legion") return "legnanotc";
	return "armnanotc";
}

string GetT1NavalNanoNameForSide(const string& in side)
{
	if (side == "armada") return "armnanotcplat";
	if (side == "cortex") return "cornanotcplat";
	if (side == "legion") return "legnanotcplat";
	return "armnanotcplat";
}

IUnitTask@ EnqueueT1Nano(const string& in unitSide, const AIFloat3& in anchor,
		float shake, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
{
	CCircuitDef@ nanoDef = ai.GetCircuitDef(GetT1NanoNameForSide(unitSide));
	if (nanoDef is null || !nanoDef.IsAvailable(ai.frame))
		return null;
	return aiBuilderMgr.Enqueue(
		TaskB::Common(Task::BuildType::NANO, prio, nanoDef, anchor, shake, true, timeoutFrames)
	);
}

IUnitTask@ EnqueueT1NavalNano(const string& in unitSide, const AIFloat3& in anchor,
		float shake, int timeoutFrames, Task::Priority prio = Task::Priority::HIGH)
{
	CCircuitDef@ nanoDef = ai.GetCircuitDef(GetT1NavalNanoNameForSide(unitSide));
	if (nanoDef is null || !nanoDef.IsAvailable(ai.frame))
		return null;
	return aiBuilderMgr.Enqueue(
		TaskB::Common(Task::BuildType::NANO, prio, nanoDef, anchor, shake, true, timeoutFrames)
	);
}

}  // namespace Builder
