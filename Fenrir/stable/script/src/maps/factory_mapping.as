// Generic factory selection helpers (extracted from Supreme Isthmus specific logic)
#include "../types/start_spot.as"

namespace FactoryMapping {
	string FactoryFor(const string &in role, const string &in side, bool landLocked) {
		if (role == "") return "";
		if (side == "armada") {
			if (role == "sea") return "armsy";
			if (role == "front") return landLocked ? "armhp" : "armvp";
			return landLocked ? "armhp" : "armlab";
		}
		if (side == "cortex") {
			if (role == "sea") return "corsy";
			if (role == "front") return landLocked ? "corhp" : "corvp";
			return landLocked ? "corhp" : "corlab";
		}
		if (side == "legion") {
			if (role == "sea") return "legsy";
			if (role == "front") return landLocked ? "leghp" : "legvp";
			return landLocked ? "leghp" : "leglab";
		}
		return "";
	}
}
