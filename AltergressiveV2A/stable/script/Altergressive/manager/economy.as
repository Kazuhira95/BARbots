#include "../../define.as"


namespace Economy {

void AiLoad(IStream& istream)
{
}

void AiSave(OStream& ostream)
{
}

/*
 * struct SResourceInfo {
 *   const float current;
 *   const float storage;
 *   const float pull;
 *   const float income;
 * }
 */
void AiUpdateEconomy()
{
	const SResourceInfo@ metal = aiEconomyMgr.metal;
	const SResourceInfo@ energy = aiEconomyMgr.energy;
	aiEconomyMgr.isMetalEmpty = metal.current < metal.storage * 0.2f;
	aiEconomyMgr.isMetalFull = metal.current > metal.storage * 0.99f;
	if (ai.frame < 3 * MINUTE) {
		aiEconomyMgr.isEnergyEmpty = false;
		aiEconomyMgr.isEnergyStalling = (energy.income < energy.pull) && (energy.current < energy.storage * 0.3f);
	} else {
		aiEconomyMgr.isEnergyEmpty = energy.current < energy.storage * 0.2f;
		aiEconomyMgr.isEnergyStalling = aiEconomyMgr.isEnergyEmpty || ((energy.income < energy.pull) && (energy.current < energy.storage * 0.6f));
	}
	// NOTE: Default energy-to-metal conversion TeamRulesParam "mmLevel" = 0.75
	aiEconomyMgr.isEnergyFull = energy.current > energy.storage * 0.95f;

	aiFactoryMgr.isAssistRequired = true;

	// Suppress T3 converters when metal income is too low to afford them
	const float minMetalIncomeForT3 = 30.0f;
	CCircuitDef@ t3a = ai.GetCircuitDef("armmmkrt3");
	if (t3a !is null) t3a.SetIgnore(metal.income < minMetalIncomeForT3);
	CCircuitDef@ t3c = ai.GetCircuitDef("cormmkrt3");
	if (t3c !is null) t3c.SetIgnore(metal.income < minMetalIncomeForT3);
	CCircuitDef@ t3l = ai.GetCircuitDef("legadveconvt3");
	if (t3l !is null) t3l.SetIgnore(metal.income < minMetalIncomeForT3);
}

}  // namespace Economy
