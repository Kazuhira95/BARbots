#include "manager/military.as"
#include "manager/factory.as"
#include "manager/builder.as"
#include "manager/economy.as"


namespace Main {

void AiMain()  // Initialize config params
{
	// waterLevel stays 0 (sea level) by default; adjust via AiGetFactoryToBuild if needed

	for (Id defId = 1, count = ai.GetDefCount(); defId <= count; ++defId) {
		CCircuitDef@ cdef = ai.GetCircuitDef(defId);
		if (cdef.costM >= 200.f && !cdef.IsMobile() && aiEconomyMgr.GetEnergyMake(cdef) > 1.f)
			cdef.AddAttribute(Unit::Attr::BASE.type);  // Build heavy energy at base
	}

	// Example of user-assigned custom attributes
	array<string> names = {Factory::armalab, Factory::coralab, Factory::armavp, Factory::coravp,
		Factory::armaap, Factory::coraap, Factory::armasy, Factory::corasy, Factory::legadvshipyard,
		Factory::legalab, Factory::legavp, Factory::legaap}; 
	for (uint i = 0; i < names.length(); ++i) {
		CCircuitDef@ cdef = ai.GetCircuitDef(names[i]);
		if (cdef !is null)
			Factory::userData[cdef.id].attr |= Factory::Attr::T2;
	}
	names = {Factory::armshltx, Factory::armshltxuw, Factory::corgant, Factory::corgantuw, Factory::leggant, Factory::leggantuw};
	for (uint i = 0; i < names.length(); ++i) {
		CCircuitDef@ cdef = ai.GetCircuitDef(names[i]);
		if (cdef !is null)
			Factory::userData[cdef.id].attr |= Factory::Attr::T3;
	}
}

void AiUpdate()  // SlowUpdate, every 30 frames with initial offset of skirmishAIId
{
	Factory::AiUpdateAirBuilders();
}

}  // namespace Main
