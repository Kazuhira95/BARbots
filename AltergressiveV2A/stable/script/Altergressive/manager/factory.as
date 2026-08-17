#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../misc/commander.as"


namespace Factory {

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

int airFactoryCount = 0;
int waterFactoryCount = 0;
bool startedOnWater = false;
int waterLevel = 0;
int nextAirBuilderFrame = 0;
array<Id> airFactoryIds;

string armlab  ("armlab");
string armalab ("armalab");
string armvp   ("armvp");
string armavp  ("armavp");
string armsy   ("armsy");
string armasy  ("armasy");
string armap   ("armap");
string armaap  ("armaap");
string armshltx("armshltx");
string armshltxuw("armshltxuw");

string corlab  ("corlab");
string coralab ("coralab");
string corvp   ("corvp");
string coravp  ("coravp");
string corsy   ("corsy");
string corasy  ("corasy");
string corap   ("corap");
string coraap  ("coraap");
string corgant ("corgant");
string corgantuw("corgantuw");

string leglab  ("leglab");
string legalab ("legalab");
string legvp   ("legvp");
string legavp  ("legavp");
string legap   ("legap");
string legsy   ("legsy");
string legadvshipyard   ("legadvshipyard");
string legaap  ("legaap");
string leggant ("leggant");
string leggantuw("leggantuw");

string armfhp("armfhp");
string corfhp("corfhp");
string legfhp("legfhp");

float switchLimit = MakeSwitchLimit();

IUnitTask@ AiMakeTask(CCircuitUnit@ unit)
{
	return aiFactoryMgr.DefaultMakeTask(unit);
}

void AiTaskAdded(IUnitTask@ task)
{
}

void AiTaskRemoved(IUnitTask@ task, bool done)
{
}

void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
{
	if (usage != Unit::UseAs::FACTORY)
		return;

	const CCircuitDef@ facDef = unit.circuitDef;

	const string name = facDef.GetName();
	if (name == Factory::armap || name == Factory::armaap || name == Factory::corap || name == Factory::coraap || name == Factory::legap || name == Factory::legaap)
		airFactoryCount++;
	if (name == Factory::armap || name == Factory::corap || name == Factory::legap)
		airFactoryIds.insertLast(unit.id);
	if (name == Factory::armsy || name == Factory::armasy || name == Factory::corsy || name == Factory::corasy || name == Factory::legsy || name == Factory::legadvshipyard
		|| name == Factory::armfhp || name == Factory::corfhp || name == Factory::legfhp)
		waterFactoryCount++;

	if (userData[facDef.id].attr & Attr::T3 != 0) {
		// if (ai.teamId != ai.GetLeadTeamId()) then this change affects only target selection,
		// while threatmap still counts "ignored" here units.
		array<string> spam = {"armpw", "corak", "armflea", "armfav", "corfav", "leggob", "legscout"};
		for (uint i = 0; i < spam.length(); ++i) {
			CCircuitDef@ cdef = ai.GetCircuitDef(spam[i]);
			if (cdef !is null)
				cdef.SetIgnore(true);
		}
	}

	const array<Opener::SO>@ opener = Opener::GetOpener(facDef);
	if (opener is null)
		return;

	const AIFloat3 pos = unit.GetPos(ai.frame);
	for (uint i = 0, icount = opener.length(); i < icount; ++i) {
		CCircuitDef@ buildDef = aiFactoryMgr.GetRoleDef(facDef, opener[i].role);
		if ((buildDef is null) || !buildDef.IsAvailable(ai.frame))
			continue;

		Task::Priority priority;
		Task::RecruitType recruit;
		if (opener[i].role == Unit::Role::BUILDER.type) {
			priority = Task::Priority::NORMAL;
			recruit  = Task::RecruitType::BUILDPOWER;
		} else {
			priority = Task::Priority::HIGH;
			recruit  = Task::RecruitType::FIREPOWER;
		}
		for (uint j = 0, jcount = opener[i].count; j < jcount; ++j)
			aiFactoryMgr.Enqueue(TaskS::Recruit(recruit, priority, buildDef, pos, 64.f));
	}
}

void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
{
	if (usage != Unit::UseAs::FACTORY)
		return;

	const CCircuitDef@ facDef = unit.circuitDef;
	const string name = facDef.GetName();
	if (name == Factory::armap || name == Factory::armaap || name == Factory::corap || name == Factory::coraap || name == Factory::legap || name == Factory::legaap) {
		airFactoryCount--;
		if (airFactoryCount < 0)
			airFactoryCount = 0;
	}
	if (name == Factory::armsy || name == Factory::armasy || name == Factory::corsy || name == Factory::corasy || name == Factory::legsy || name == Factory::legadvshipyard
		|| name == Factory::armfhp || name == Factory::corfhp || name == Factory::legfhp) {
		waterFactoryCount--;
		if (waterFactoryCount < 0)
			waterFactoryCount = 0;
	}
	if (name == Factory::armap || name == Factory::corap || name == Factory::legap) {
		for (uint i = 0; i < airFactoryIds.length(); ++i) {
			if (airFactoryIds[i] == unit.id) {
				airFactoryIds.removeAt(i);
				break;
			}
		}
	}
}

void AiUpdateAirBuilders()
{
	if (ai.frame < nextAirBuilderFrame)
		return;
	nextAirBuilderFrame = ai.frame + 900 * SECOND;

	if (airFactoryIds.length() == 0)
		return;

	CCircuitUnit@ factory = ai.GetTeamUnit(airFactoryIds[0]);
	if (factory is null)
		return;

	CCircuitDef@ buildDef = aiFactoryMgr.GetRoleDef(factory.circuitDef, RT::BUILDER);
	if (buildDef is null || !buildDef.IsAvailable(ai.frame))
		return;

	const AIFloat3 pos = factory.GetPos(ai.frame);
	for (uint i = 0; i < 10; ++i)
		aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NORMAL, buildDef, pos, 64.f));
}

void AiLoad(IStream& istream)
{
	istream >> airFactoryCount >> waterFactoryCount >> startedOnWater;
}

void AiSave(OStream& ostream)
{
	ostream << airFactoryCount << waterFactoryCount << startedOnWater;
}

/*
 * New factory switch condition; switch event is also based on eco + caretakers.
 */
bool AiIsSwitchTime(int lastSwitchFrame)
{
	const float value = pow((ai.frame - lastSwitchFrame), 0.9) * aiEconomyMgr.metal.income + (aiEconomyMgr.metal.current * 7);
	if (value > switchLimit) {
		switchLimit = MakeSwitchLimit();
		return true;
	}
	return false;
}

bool AiIsSwitchAllowed(CCircuitDef@ facDef)
{
	return true;
}

CCircuitDef@ AiGetFactoryToBuild(const AIFloat3& in pos, bool isStart, bool isReset)
{
	if (isStart)
		startedOnWater = pos.y <= waterLevel;
	if (isReset)
		airFactoryCount = waterFactoryCount = 0;
	CCircuitDef@ facDef = aiFactoryMgr.DefaultGetFactoryToBuild(pos, isStart, isReset);

	if (facDef !is null && IsLandGantryFactory(facDef.GetName()) && Military::mexPositions.length() > 0) {
		float closestDist;
		AIFloat3 closestMex = Military::GetClosestMexPos(pos, closestDist);
		if (closestDist < GANTRY_MEX_MARGIN) {
			// Push gantry away from nearest mex
			float dx = pos.x - closestMex.x;
			float dz = pos.z - closestMex.z;
			float d = sqrt(dx * dx + dz * dz);
			if (d < 1.f) { dx = 1.f; dz = 0.f; d = 1.f; }
			float push = GANTRY_MEX_MARGIN - d + SQUARE_SIZE * 8;
			gantryBuildPos.x = pos.x + dx / d * push;
			gantryBuildPos.z = pos.z + dz / d * push;
			gantryBuildPos.y = pos.y;
			hasGantryBuildPos = true;
		}
	}
	return facDef;
}

/* --- Nano enqueue with shake --- */

/* --- Gantry placement helpers --- */

// Stored adjusted position for land gantry to avoid mexes
AIFloat3 gantryBuildPos(0.f, 0.f, 0.f);
bool hasGantryBuildPos = false;

bool IsLandGantryFactory(const string& in name)
{
	return name == "armshltx" || name == "corgant" || name == "leggant";
}

bool IsGantryFactory(const string& in name)
{
	return name == "armshltx"   || name == "corgant"   || name == "leggant"
		|| name == "armshltxuw" || name == "corgantuw" || name == "leggantuw"
		|| name == "armapt3"    || name == "corapt3"   || name == "legapt3";
}

AIFloat3 GetGantryBuildPos()
{
	return gantryBuildPos;
}

bool HasGantryBuildPos()
{
	return hasGantryBuildPos;
}

void ClearGantryBuildPos()
{
	hasGantryBuildPos = false;
}

const float GANTRY_MEX_MARGIN = SQUARE_SIZE * 100;  // gantry footprint + nano shake (40) + mex footprint + buffer

bool IsT2Factory(const string& in name)
{
	return name == "armap" || name == "armaap" || name == "armavp" || name == "armalab"
		|| name == "corap" || name == "coraap" || name == "coravp" || name == "coralab"
		|| name == "legap" || name == "legaap" || name == "legavp" || name == "legalab";
}

bool IsWaterFactory(const string& in name)
{
	return name == "armsy" || name == "armasy"
		|| name == "corsy" || name == "corasy"
		|| name == "legsy" || name == "legadvshipyard"
		|| name == "armfhp" || name == "corfhp" || name == "legfhp";
}

IUnitTask@ EnqueueNanoForFactory(CCircuitUnit@ factoryUnit, Task::Priority prio = Task::Priority::HIGH)
{
	if (factoryUnit is null || factoryUnit.circuitDef is null)
		return null;
	const string name = factoryUnit.circuitDef.GetName();
	const AIFloat3 pos = factoryUnit.GetPos(ai.frame);
	const int shake = IsGantryFactory(name) ? SQUARE_SIZE * 70 : SQUARE_SIZE * 24; //40 ,24

	string nanoName;
if (IsT2Factory(name)) {
    if (IsWaterFactory(name)) {
        if (name.substr(0, 3) == "cor")
            nanoName = "cornanotc2plat";
        else if (name.substr(0, 3) == "leg")
            nanoName = "legnanotct2plat";
        else
            nanoName = "armnanotct2plat";
    } else {
        if (name.substr(0, 3) == "cor")
            nanoName = "cornanotct2";
        else if (name.substr(0, 3) == "leg")
            nanoName = "legnanotct2";
        else
            nanoName = "armnanotct2";
    }
} else {
    if (IsWaterFactory(name)) {
        if (name.substr(0, 3) == "cor")
            nanoName = "cornanotcplat";
        else if (name.substr(0, 3) == "leg")
            nanoName = "legnanotcplat";
        else
            nanoName = "armnanotcplat";
    } else {
        if (name.substr(0, 3) == "cor")
            nanoName = "cornanotc";
        else if (name.substr(0, 3) == "leg")
            nanoName = "legnanotc";
        else
            nanoName = "armnanotc";
    }
}
	CCircuitDef@ nanoDef = ai.GetCircuitDef(nanoName);
	if (nanoDef is null || !nanoDef.IsAvailable(ai.frame))
		return null;
	return aiBuilderMgr.Enqueue(
		TaskB::Common(Task::BuildType::NANO, prio, nanoDef, pos, float(shake), true, 300 * SECOND)
	);
}

/* --- Utils --- */

float MakeSwitchLimit()
{
	return 5000 * SECOND;
}

}  // namespace Factory
