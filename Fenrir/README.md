# Fenrir AI Profile

Role-based experimental skirmish AI for **Beyond All Reason (BAR)** built on the BARbarIAn C++ AI wrapper. Developed by Felnious, modified by Kazuhira95.

Unlike generic AI profiles, Fenrir assigns itself a deterministic strategic role based on nearest map-defined start position and tailors all build decisions, economy thresholds, and military behavior to that role. This enables specialized play across Front, Air, Tech, Sea, and Hover scenarios with zero speculative initialization.

## Architecture Overview

```
stable/
  AIInfo.lua          – Identity: shortName="Fenrir", version="stable"
  AIOptions.lua       – Lobby options (difficulty profile, LOS cheat, unit blacklist)
  SkirmishAI.dll      – Compiled C++ AI interface
  angelscript-references.md
  config/Fenrir/      – Per-side factory weight tables (JSON)
  script/
    Fenrir/
      main.as         – Entry point: AiMain, AiUpdate, strategy weighting
      init.as         – Early initialization glue
    src/
      setup.as        – Deferred map/profile setup + factory hook override
      global.as       – All role settings, economy trackers, static state
      common.as       – Faction side registrations + armor definitions
      maps.as         – Map config registry (18 maps)
      define.as       – Core engine / integration constants
      unit.as         – Unit/definition access helpers
      task.as         – Task abstractions
      types/          – Data types
        ai_role.as             – AiRole enum: FRONT, AIR, TECH, SEA, FRONT_TECH, HOVER_SEA
        role_config.as         – RoleConfig class with delegate-based hooks
        profile_controller.as  – Per-role update dispatcher
        strategy.as            – Strategy enum (T2_RUSH, T3_RUSH, NUKE_RUSH) + bitmask helpers
        opener.as              – Initial build order sequences
        map_config.as          – MapConfig container (start spots, unit limits, objectives)
        start_spot.as          – StartSpot (pos, role, landLocked flag)
        terrain.as             – Terrain classification
        strategic_objectives.as – Multi-step objective chains
      roles/          – Per-role behavior handlers
        front.as            – FRONT: T1 bots/vehicles, T2 transition, scout rushes
        front_tech.as       – FRONT_TECH: hybrid frontline + tech economy
        tech.as             – TECH: T2/T3 rush, nuke strategy, gantry, donation
        air.as              – AIR: fighters, bombers, bomber gate, support wings
        sea.as              – SEA: shipyards, destroyer/AA/flag-ship quotas
        hover_sea.as        – HOVER_SEA: hovercraft rush, amphibious, objectives
      helpers/        – Shared utilities
        generic_helpers.as   – Logging, distance, start recording
        map_helpers.as       – Nearest spot, land-lock detection
        unit_helpers.as      – Side-indexed unit name resolution (per faction)
        unitdef_helpers.as   – Count queries, SetIgnore, SetMainRole
        builder_helpers.as   – Common builder enqueue logic
        factory_helpers.as   – Factory weight selection, role-based start factories
        economy_helpers.as   – Converter/nano/fusion/anti-nuke decision helpers
        defense_helpers.as   – Defense placement helpers
        guard_helpers.as     – Worker guard assignment
        limits_helpers.as    – Unit limit merging (map + role)
        role_helpers.as      – Default role from factory name
        role_limit_helpers.as– Per-role start limits
        task_helpers.as      – Task utilities
        collection_helpers.as– Dictionary helpers
        objective_helpers.as – Objective query, assignment, completion tracking
        objective_executor.as– Execute objective chain steps
        terrain_helpers.as   – Terrain analysis
      manager/        – Cross-role subsystems
        factory.as           – Factory manager: primaries, nano enqueue, gantry batches
        builder.as           – Builder manager: constructors, guards, tactical state
        economy.as           – Economy thresholds, income trackers, switch conditions
        military.as          – Combat unit grouping, quotas, attack coordination
      maps/           – Static data-only map configurations (18 maps)
        default_map_config.as
        supreme_isthmus.as, all_that_glitters.as, swirly_rock.as, eight_horses.as,
        flats_and_forests.as, glacial_gap.as, forge.as, red_river_estuary.as,
        serene_caldera.as, shore_to_shore.as, koom_valley.as, acidic_quarry.as,
        tempest.as, tundra_continents.as, raptor_crater.as, sinkhole_network.as,
        ancient_bastion_remake.as, mediterraneum.as, factory_mapping.as
      misc/
        commander.as  – Commander-specific logic (morphing, safety, openers)
```

## Six Roles

|       Role      |            Description           |
|-----------------|----------------------------------|
|     **FRONT**   | Unified `TECH`/`AIR`/`SEA` (Agressive) Role  |
|     **AIR**     | Air superiority; fighters, bombers, support wings; bomber gate (support→bomber role switch at threshold); T2 heavy air strikes; target T2 bomber counts |
|     **TECH**    | T2/T3 rush/nuke strategies; income-scaled gantries; advanced energy; donation of 3rd T2 constructor to team leader |
|  **FRONT_TECH** | Hybrid frontline + eco; T2 lab progression; early converters; secondary T1 assist |
|     **SEA**     | Naval combat; T2 destroyer/AA ship/flagship quotas; resurrection submarine policy; T2 constructor donation |
|  **HOVER_SEA**  | Hovercraft combat rush; objectives-driven expansion; income-scaled hover plants; T2 vehicle transition; T2 shipyard with high quotas |

## Strategy System (TECH Role)

Three high-level strategies are evaluated via weighted dice at game start:

| Strategy | Weight | Behavior |
|----------|--------|----------|
| **T2_RUSH** | 85% | Always enabled — minimized income gates for T2 bot lab |
| **T3_RUSH** | 35% | Enable gantry progression and experimental production |
| **NUKE_RUSH** | 25% | Unlock nuclear silos at lower income thresholds (always enabled if landlocked) |

Strategies are bitmask flags in `Global::RoleSettings::Tech::StrategyMask`. Enable/disable via `EnableStrategy`/`DisableStrategy` helpers.

## Key Behaviors

- **Deterministic role assignment**: Role chosen by nearest `StartSpot` to actual first factory position; no speculation.
- **Deferred initialization**: Map + role + factory resolved only when `AiGetFactoryToBuild` is called with `isStart=true`.
- **Income-scaled unit caps**: Dynamic factory limits per role (e.g., N gantries at `metalIncome / 250`).
- **Aggressive fire state**: FRONT, SEA, and HOVER_SEA set fire state 3 (fire at everything) on T1 combat units.
- **Donation system**: TECH and SEA donate their 3rd T2 constructor to the team leader.
- **Bomber gate**: AIR role tracks T2 bombers; when count ≥ `BomberGateOpenThreshold`, all T2 bomber defs switch to mainRole `"bomber"` with SIEGE attribute; reverts when count falls below threshold.
- **Support fighter wing**: AIR maintains a home-defense wing of T2 fighters (BASE-tagged) near base.
- **Strategic Objectives**: Multi-step build chains per map (e.g., seaplane platform → tidals → completion); objective-driven factory placement.
- **Landlocked detection**: TECH uses amphibious units and torpedo bombers on landlocked starts; AIR role uses torpedo bombers.

## Factory Selection

Role-specific handlers evaluate start factories and switches:

- **Start**: Uses `FactoryHelpers::SelectStartFactoryForRole(role, side)` which checks map-configured `FactoryWeights` first, then falls back to role defaults.
- **Switch (non-start)**:
  - FRONT: checks map factory weights → builds missing T1/T2 factories in priority order.
  - Others (AIR, TECH, FRONT_TECH, SEA): start only; switches deferred to manager logic.
  - HOVER_SEA: always starts with hover plant; switches resolve to next missing factory type.

## Per-Role Settings

All configurable thresholds live in `Global::RoleSettings::{Front,Air,Tech,FrontTech,Sea,HoverSea}` in `global.as`. Key categories:

- **Military quotas**: Scout cap, attack gate (power), raid min/average power
- **Economy thresholds**: Income gates for T2 labs, solars, converters, fusion reactors, gantries
- **Nano policy**: Income per nano unit, max count, reserves-based build triggers
- **Builder caps**: T1/T2 constructor limits per role
- **Factory limits**: Income-scaled plant allowances per tier
- **Switch cadence**: Min/max seconds between factory switches
- **Anti-nuke policy**: Economy thresholds and count targets
- **Start limits**: Per-role initial unit caps applied at game start

## 18 Supported Maps

Acidic Quarry, All That Glitters, Ancient Bastion Remake, Eight Horses, Flats and Forests, Forge, Glacial Gap, Koom Valley, Mediterraneum, Raptor Crater, Red River Estuary, Serene Caldera, Shore to Shore, Sinkhole Network, Supreme Isthmus, Swirly Rock, Tempest, Tundra Continents
|Tested:`All That Glitters`, `Shore to Shore`|
## Extending

1. **New map**: Create `maps/<name>.as` with `StartSpot[]` + `MapConfig` + optional objectives; register in `maps.as::registerMaps()`.
2. **New role**: Extend `AiRole` enum, create handler under `roles/`, register in `setup.as::RegisterRoles()`.
3. **New strategy**: Add enum value in `strategy.as`, weights in `main.as::StrategyWeights`, check via `HasStrategy()`.
4. **Tune thresholds**: Adjust constants in the relevant `Global::RoleSettings::*` namespace in `global.as`.

## Debugging

- Verbosity level 2: side detection, selected role, chosen factory, strategy decisions.
- Verbosity level 3+: detailed economy snapshots, limit applications, objective traces.
- Look for `[Factory]`, `[MapRegistry]`, `[RoleMatch]`, `[Strategy]` log prefixes.
- Console command: `smrt status` (via Lua message, currently commented out) reports economy snapshots.

## Known Limitations

- No embedded factory selection logic in map files (static data only).
- Fire-state API may not be exposed engine-side; best-effort application.
- Factory `FactoryWeights` configured in map configs may conflict with hardcoded role priority order.
- Water coverage percentage unavailable via current script API.
- Map start positions must have correct `AiRole` assigned for optimal role detection.
