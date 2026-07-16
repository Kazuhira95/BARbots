#include "../common.as"
#include "../unit.as"


namespace Init {

SInitInfo AiInit()
{
	AiLog("hard_aggressive AngelScript Rules!");

	SInitInfo data;
	data.armor = InitArmordef();
	data.category = InitCategories();
	@data.profile = @(array<string> = {"V2A_behaviour", "V2A_block_map", "V2A_build_chain", "V2A_commander", "V2A_economy", "V2A_factory", "V2A_response"});
	if (string(aiSetupMgr.GetModOptions()["experimentallegionfaction"]) == "1") {
		AiLog("Inserting Legion");
		Side::LEGION = aiSideMasker.GetTypeMask("legion");
		data.profile.insertAt(data.profile.length(), {"V2A_behaviour_leg", "V2A_build_chain_leg", "V2A_commander_leg", "V2A_economy_leg", "V2A_factory_leg"});
	} else {
		AiLog("Ignoring Legion");
	}
	if (string(aiSetupMgr.GetModOptions()["scavunitsforplayers"]) == "1") {
		AiLog("Inserting Scav Units");
		data.profile.insertAt(data.profile.length(), {"V2A_behaviour_scav_units"});
	} else {
		AiLog("Ignoring Scav Units");
	}
	if (string(aiSetupMgr.GetModOptions()["experimentalextraunits"]) == "1") {
		AiLog("Inserting Extra Units");
		data.profile.insertAt(data.profile.length(), {"V2A_behaviour_extra_units"});
	} else {
		AiLog("Ignoring Extra Units");
	}
	return data;
}

}
