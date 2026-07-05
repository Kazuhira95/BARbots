#include "../unit.as"
#include "../task.as"
#include "../define.as"
#include "../global.as"
#include "../types/ai_role.as"
#include "../types/start_spot.as" // for StartSpot & AIFloat3

namespace MapHelpers {
    float SqDist(const AIFloat3& in a, const AIFloat3& in b) {
        float dx = a.x - b.x; float dz = a.z - b.z; return dx*dx + dz*dz;
    }

    int NearestSpotIdx(const AIFloat3& in refPos, StartSpot@[]@ list) {
        float best = 1e30f; int bestIdx = -1;
        if (list is null) return -1;
        for (uint i = 0; i < list.length(); ++i) {
            float d = SqDist(refPos, list[i].pos);
            if (d < best) { best = d; bestIdx = int(i); }
        }
        return bestIdx;
    }

    StartSpot@ NearestSpot(const AIFloat3& in refPos, StartSpot@[]@ list) {
        int idx = NearestSpotIdx(refPos, list);
        return (idx >= 0) ? list[idx] : null;
    }

    bool IsLandLocked(StartSpot@ spot) { return (spot is null) ? false : spot.landLocked; }

    bool IsLandlockedMap(const string &in mapName) {
        // Sea maps
        if (mapName.findFirst("Tundra Continents") == 0) return true;
        if (mapName.findFirst("Shore_to_Shore") == 0) return true;
        if (mapName.findFirst("Serene Caldera") == 0) return true;
        // Hybrid land/sea maps
        if (mapName.findFirst("Glacial Gap") == 0) return true;
        if (mapName.findFirst("Mediterraneum") == 0) return true;
        if (mapName.findFirst("Red River Estuary") == 0) return true;
        if (mapName.findFirst("Supreme Isthmus") == 0) return true;
        return false;
    }

    // Return true if p1 is within 'range' of p2 (2D distance using x/z). Range <= 0 returns false.
    bool IsInRange(const AIFloat3& in p1, const AIFloat3& in p2, float range)
    {
        if (range <= 0.0f) return false;
        const float dx = p1.x - p2.x;
        const float dz = p1.z - p2.z;
        const float r = range;
        return (dx * dx + dz * dz) <= (r * r);
    }

    // Return true if the given unit's current position is within 'range' of the task's build position.
    // Null-safe: returns false if unit or task is null.
    bool IsUnitInRangeOfTask(CCircuitUnit@ unit, IUnitTask@ task, float range)
    {
        if (unit is null || task is null) return false;
        const AIFloat3 upos = unit.GetPos(ai.frame);
        const AIFloat3 tpos = task.GetBuildPos();
        return IsInRange(upos, tpos, range);
    }
}