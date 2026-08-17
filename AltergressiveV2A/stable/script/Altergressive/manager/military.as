#include "../../define.as"
#include "../../unit.as"


namespace Military {

// Track mex positions for gantry placement
array<AIFloat3> mexPositions;
array<Id> mexUnitIds;

bool IsMexDef(const string& in name)
{
	return name == "armmex" || name == "cormex" || name == "legmex"
		|| name == "armmoho" || name == "cormoho" || name == "legmoho"
		|| name == "armuwmme" || name == "coruwmme";
}

AIFloat3 GetClosestMexPos(const AIFloat3& in pos, float& out dist)
{
	AIFloat3 best(0.f, 0.f, 0.f);
	dist = 1e9f;
	for (uint i = 0; i < mexPositions.length(); ++i) {
		float dx = pos.x - mexPositions[i].x;
		float dz = pos.z - mexPositions[i].z;
		float d = sqrt(dx * dx + dz * dz);
		if (d < dist) {
			dist = d;
			best = mexPositions[i];
		}
	}
	return best;
}

IUnitTask@ AiMakeTask(CCircuitUnit@ unit)
{
	return aiMilitaryMgr.DefaultMakeTask(unit);
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
	if (cdef !is null && IsMexDef(cdef.GetName())) {
		mexPositions.insertLast(unit.GetPos(ai.frame));
		mexUnitIds.insertLast(unit.id);
	}
}

void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
{
	if (unit is null) return;
	const CCircuitDef@ cdef = unit.circuitDef;
	if (cdef !is null && IsMexDef(cdef.GetName())) {
		for (uint i = 0; i < mexUnitIds.length(); ++i) {
			if (mexUnitIds[i] == unit.id) {
				mexPositions.removeAt(i);
				mexUnitIds.removeAt(i);
				break;
			}
		}
	}
}

void AiLoad(IStream& istream)
{
}

void AiSave(OStream& ostream)
{
}

void AiMakeDefence(int cluster, const AIFloat3& in pos)
{
	if ((ai.frame > 5 * MINUTE)
		|| (aiEconomyMgr.metal.income > 10.f)
		|| (aiEnemyMgr.mobileThreat > 0.f))
	{
		aiMilitaryMgr.DefaultMakeDefence(cluster, pos);
	}
}

/*
 * anti-air threat threshold;
 * air factories will stop production when AA threat exceeds
 */
// FIXME: Remove/replace, deprecated.
bool AiIsAirValid()
{
	return aiEnemyMgr.GetEnemyThreat(Unit::Role::AA.type) <= 80.f;
}

}  // namespace Military
