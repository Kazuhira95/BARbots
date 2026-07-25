#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace ShoreToShore {
	/*
	Shore_to_Shore_V3 map profile
	- Purpose: Provide start spots, per-role factory weights, and per-map unit caps.
	- Notes:
	  * Vehicle plants are disabled via map unit limits (water-heavy map); weights may still list them for consistency across roles, but caps prevent building.
	  * landLocked is currently false for all spots. If peninsulas/islands are detected later, we can flip to require hover/amph starts.
	*/

	// Start spots for Shore_to_Shore_V3 (converted from YAML, roles matched to AiRole enum)
	// landLocked heuristic: currently false for all
	StartSpot@[] spots = {
		StartSpot(AIFloat3(  560, 0,  730), AiRole::HOVER_SEA, false), //TECH
		StartSpot(AIFloat3(  550, 0, 1740), AiRole::AIR,       false), //AIR
		StartSpot(AIFloat3(  340, 0, 2700), AiRole::TECH,      false), //HOVER_SEA

		StartSpot(AIFloat3( 2000, 0,  730), AiRole::SEA,       false), //SEA
		StartSpot(AIFloat3( 2000, 0, 1740), AiRole::SEA,       false), //SEA
		StartSpot(AIFloat3( 2000, 0, 2700), AiRole::SEA,       false), //SEA

		StartSpot(AIFloat3(14800, 0,  550), AiRole::TECH,      false), //TECH
		StartSpot(AIFloat3(14800, 0, 1450), AiRole::AIR,       false), //AIR
		StartSpot(AIFloat3(14800, 0, 2300), AiRole::HOVER_SEA, false), //HOVER_SEA

		StartSpot(AIFloat3(13250, 0,  730), AiRole::SEA,       false), //SEA
		StartSpot(AIFloat3(13250, 0, 1740), AiRole::SEA,       false), //SEA
		StartSpot(AIFloat3(13250, 0, 2700), AiRole::SEA,       false)  //SEA
	};

	// Role-specific unit limit overlays (roleKey -> (unitName -> cap))
	// Currently unused; keep for future role gating.
	dictionary getRoleUnitLimits()
	{
		dictionary roleUnitLimits;
		dictionary hoverSeaLimits;
		hoverSeaLimits.set("armhp", 1);
		hoverSeaLimits.set("corhp", 1);
		hoverSeaLimits.set("leghp", 1);
		hoverSeaLimits.set("armfhp", 1);
		hoverSeaLimits.set("corfhp", 1);
		hoverSeaLimits.set("legfhp", 1);
		roleUnitLimits.set("HOVER_SEA", @hoverSeaLimits);
		return roleUnitLimits;
	}

	// Base per-map unit limits (disallow vehicle plants). Add more as needed.
	dictionary getMapUnitLimits()
	{
		dictionary limits;
		// Allow T1 land factories so T1 constructors can be built
		limits.set("armvp", 0);
		limits.set("corvp", 0);
		limits.set("legvp", 0);
		// Disable T2 vehicle plants (land)
		// limits.set("armavp", 0);
		// limits.set("coravp", 0);
		// limits.set("legavp", 0);

		// Prevent all land T1 combat units (constructors remain allowed). Hover units remain allowed.
		// ARMADA - T1 land combat bots
		limits.set("armpw", 0);    // Pawn (raider bot)
		limits.set("armwar", 0);   // Centurion (riot bot)
		limits.set("armrock", 0);
		limits.set("armham", 0);
		limits.set("armflea", 0);  // Rocket Bot
		// ARMADA - T2 land combat bots
		limits.set("armzeus", 0);
		limits.set("armmav", 0);
		limits.set("armfast", 0);
		limits.set("armaser", 0);
		limits.set("armspid", 0);
		limits.set("armscab", 0);
		limits.set("armsptk", 0);
		limits.set("armsnipe", 0);
		limits.set("armspy", 0);
		limits.set("armfboy", 0);
		limits.set("armfido", 0);
		limits.set("armmark", 0);
		// ARMADA - T1 land combat vehicles
		limits.set("armflash", 0); // Fast Assault Tank
		limits.set("armstump", 0); // Medium Assault Tank
		limits.set("armart", 0);   // Light Artillery Vehicle
		limits.set("armsam", 0);   // Missile Truck
		limits.set("armjanus", 0); // Twin Medium Rocket Launcher
		limits.set("armyork", 0);  // AA Flak Vehicle
		limits.set("armgremlin", 0); // Stealth Tank
		limits.set("armfav", 0);
		limits.set("armzapper", 0);
		// ARMADA - T2 land combat vehicles
		limits.set("armmanni", 0);
		limits.set("armjam", 0);
		limits.set("armmerl", 0);
		limits.set("armseer", 0);
		limits.set("armgremlin", 0);
		limits.set("armmart", 0);
		limits.set("armlatnk", 0);
		limits.set("armbull", 0);
		limits.set("armyork", 0);

		// CORTEX - T1 land combat bots
		limits.set("corak", 0);    // Fast Infantry Bot (raider)
		limits.set("corthud", 0);  // Light Plasma Bot (riot)
		limits.set("corstorm", 0); // Rocket Bot (skirm)
		// CORTEX - T2 land combat bots
		limits.set("cordeadeye", 0);
		limits.set("cortermite", 0);
		limits.set("corpyro", 0);
		limits.set("corsumo", 0);
		limits.set("corhrk", 0);
		limits.set("corvoyr", 0);
		limits.set("corcan", 0);
		limits.set("corspec", 0);
		limits.set("cormort", 0);
		limits.set("corspy", 0);
		// CORTEX - T1 land combat vehicles
		limits.set("corgator", 0); // Light Tank (raider)
		limits.set("corraid", 0);  // Medium Assault Tank
		limits.set("corlevlr", 0); // Anti-Swarm Tank (riot)
		limits.set("corwolv", 0);  // Light Mobile Artillery
		limits.set("cormist", 0);  // Missile Truck
		limits.set("corfav", 0);
		// CORTEX - T2 land combat vehicles
		limits.set("corban", 0);
		limits.set("correap", 0);
		limits.set("corgol", 0);
		limits.set("cortorch", 0);
		limits.set("corsiegebreaker", 0);
		limits.set("corsala", 0);
		limits.set("coreter", 0);
		limits.set("cormart", 0);
		limits.set("corvrad", 0);
		limits.set("cortrem", 0);
		limits.set("corvroc", 0);
		limits.set("corsent", 0);

		// LEGION - T1 land combat bots
		limits.set("leggob", 0);   // Light Skirmish Bot
		limits.set("legshot", 0);  // Shielded Riot Bot
		limits.set("legstr", 0);   // Fast Raider Bot
		// LEGION - T1 land combat vehicles
		limits.set("legmrv", 0);   // Fast Raider Vehicle
		limits.set("leghelios", 0); // Skirmisher Tank
		// LEGION - T2 land combat vehicles
		limits.set("legavroc", 0);
		limits.set("legvflak", 0);
		limits.set("legaheattank", 0);
		limits.set("legamcluster", 0);
		limits.set("legmed", 0);
		limits.set("legavrad", 0);
		limits.set("legavjam", 0);
		limits.set("legaskirmtank", 0);
		limits.set("legvcarry", 0);

		// Set limits to Contruction units
		// Armada - T1 land CON BOTs
		limits.set("armck", 50);
		// Armada - T1 land CON VEHs
		limits.set("armcv", 50);
		// Armada - T1 land CON AIRs //structure on land that creates AIR units, hence land

		// Armada - T2 land CON BOTs
		limits.set("armack", 50);
		limits.set("armfark", 50);
		// Armada - T2 land CON VEHs
		limits.set("armacv", 50);
		limits.set("armconsul", 50);
		// Armada - T2 land CON AIRs

		// Cortex - T1 land CON BOTs
		limits.set("corck", 50);
		// Cortex - T1 land CON VEHs
		limits.set("corcv", 50);
		// Cortex - T1 land CON AIRs

		// Cortex - T2 land CON BOTs
		limits.set("corack", 50);
		limits.set("corfast", 50);
		// Cortex - T2 land CON VEHs
		limits.set("coracv", 50);
		// Cortex - T2 land CON AIRs

		// Legion - T1 land CON BOTs
		limits.set("legck", 50);
		// Legion - T1 land CON VEHs
		limits.set("legcv", 50);
		// Legion - T1 land CON AIRs

		// Legion - T2 land CON BOTs
		limits.set("legack", 50);
		limits.set("legaceb", 50);
		// Legion - T2 land CON VEHs
		limits.set("legacv", 50);
		limits.set("legafcv", 50);
		// Legion - T2 land CON AIRs
		return limits;
	}

	// Example factory weights per role (higher weight => more likely)
	// Schema v2: role -> ( side -> (factory -> weight) )
	dictionary getFactoryWeights()
	{
		dictionary root; // role -> sideDict

		// FRONT role
		dictionary frontArm; frontArm.set("armlab", 2); frontArm.set("armvp", 5);
		dictionary frontCor; frontCor.set("corlab", 2); frontCor.set("corvp", 5);
		dictionary frontLeg; frontLeg.set("leglab", 2); frontLeg.set("legvp", 5);
		dictionary frontRole; frontRole.set("armada", @frontArm); frontRole.set("cortex", @frontCor); frontRole.set("legion", @frontLeg);
		root.set("FRONT", @frontRole);

		// AIR role
		dictionary airArm; airArm.set("armap", 3);
		dictionary airCor; airCor.set("corap", 3);
		dictionary airLeg; airLeg.set("legap", 3);
		dictionary airRole; airRole.set("armada", @airArm); airRole.set("cortex", @airCor); airRole.set("legion", @airLeg);
		root.set("AIR", @airRole);

		// SEA role
		dictionary seaArm; seaArm.set("armsy", 4);
		dictionary seaCor; seaCor.set("corsy", 4);
		dictionary seaLeg; seaLeg.set("legsy", 4);
		dictionary seaRole; seaRole.set("armada", @seaArm); seaRole.set("cortex", @seaCor); seaRole.set("legion", @seaLeg);
		root.set("SEA", @seaRole);

		// HOVER_SEA role
		dictionary hoverSeaArm; hoverSeaArm.set("armhs", 4); hoverSeaArm.set("armhp", 4); hoverSeaArm.set("armsy", 4);
		dictionary hoverSeaCor; hoverSeaCor.set("corhs", 4); hoverSeaCor.set("corhp", 4); hoverSeaCor.set("corsy", 4);
		dictionary hoverSeaLeg; hoverSeaLeg.set("leghs", 4); hoverSeaLeg.set("leghp", 4); hoverSeaLeg.set("legsy", 4);
		dictionary hoverSeaRole; hoverSeaRole.set("armada", @hoverSeaArm); hoverSeaRole.set("cortex", @hoverSeaCor); hoverSeaRole.set("legion", @hoverSeaLeg);
		root.set("HOVER_SEA", @hoverSeaRole);

		// TECH role
		dictionary techArm; techArm.set("armlab", 4);
		dictionary techCor; techCor.set("corlab", 4);
		dictionary techLeg; techLeg.set("leglab", 4);
		dictionary techRole; techRole.set("armada", @techArm); techRole.set("cortex", @techCor); techRole.set("legion", @techLeg);
		root.set("TECH", @techRole);

		// FRONT_TECH role
		dictionary frontTechHybridArm; frontTechHybridArm.set("armlab", 4);
		dictionary frontTechHybridCor; frontTechHybridCor.set("corlab", 4);
		dictionary frontTechHybridLeg; frontTechHybridLeg.set("leglab", 4);
		dictionary frontTechHybridRole; frontTechHybridRole.set("armada", @frontTechHybridArm); frontTechHybridRole.set("cortex", @frontTechHybridCor); frontTechHybridRole.set("legion", @frontTechHybridLeg);
		root.set("FRONT_TECH", @frontTechHybridRole);

		return root;
	}

	// Consolidated map config
	MapConfig config = MapConfig("Shore_to_Shore_V3", getMapUnitLimits(), spots, getFactoryWeights(), getRoleUnitLimits());

}
