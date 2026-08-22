# Alerter — Capability Matrix (verification tracker)

The [design](DESIGN.md) is a wishlist. This file is the ground-truth ledger:
every capability the design leans on, how we test it in live 12.1, and what
part of the design falls or changes if it isn't there.

**Status legend:** ⬜ untested · ✅ works · ⚠️ partial / conditional · ❌ not
available. Everything starts ⬜. We fill this in from a probe run in-game
(§ Test protocol), then revise the design to match.

> Rule: no capability graduates to a design dependency until it's ✅ or ⚠️ with
> the condition understood. ❌ or surprising ⚠️ results edit the design.

---

## A. Enemy casts (the detection floor)

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| A1 | See enemy `SPELL_CAST_START` in instances | `COMBAT_LOG_EVENT_UNFILTERED` | everything | ⬜ | |
| A2 | See enemy `SPELL_CAST_SUCCESS` | CLEU | timeline, instant casts | ⬜ | |
| A3 | Read cast **duration** at start | CLEU payload / `UnitCastingInfo` on caster | bar vs flash render | ⬜ | |
| A4 | Read **interruptible** flag at cast time | CLEU `notInterruptible` / nameplate `UnitCastingInfo` | "Stop it" intent | ⬜ | which source is reliable? |
| A5 | Distinguish channel vs cast | `UnitChannelInfo` | render | ⬜ | |

## B. Target resolution (the crux — §7.1 of design)

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| B1 | `destGUID` present on a cast SUCCESS | CLEU | "On me" / "targeted" | ⬜ | present for which spells? |
| B2 | Map a cast to caster's **nameplate unit** | GUID ↔ `nameplateN` scan | target via UnitCastingInfo | ⬜ | |
| B3 | Read who a nameplate unit is **casting at** | `UnitCastingInfo` gives no target — need target-of-target? | targeted alerts | ⬜ | likely no direct API |
| B4 | Catch "targeted" via **debuff application** | `SPELL_AURA_APPLIED` destGUID | targeted-by-debuff fallback | ⬜ | probably the real path |
| B5 | Know if a target is **me** vs a party member | GUID compare to `UnitGUID("player"/"partyN")` | "On me" priority | ⬜ | |

## C. Auras & instant mechanics (§7.3)

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| C1 | See debuffs applied to party members | `UNIT_AURA` / `SPELL_AURA_APPLIED` | group-react, targeted | ⬜ | |
| C2 | Read aura **duration/expiration** on others | `C_UnitAuras.GetAuraDataByIndex` | timers on party | ⬜ | secret? |
| C3 | Detect no-cast mechanics (damage/summon) | CLEU `SPELL_DAMAGE` / `SPELL_SUMMON` | instant lethal mechanics | ⬜ | how much of "matters" is this |

## D. Secret values (12.1 reality — §Principles)

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| D1 | Which cast/aura reads come back **secret in combat** | `issecretvalue` on each read | everything (fail-open design) | ⬜ | enumerate what's secret |
| D2 | Read **my own** interrupt availability | `C_Spell.IsSpellUsable` / cooldown | capability filter ("Stop it" only if I can) | ⬜ | |
| D3 | Read **enemy** cast fields without secret block | CLEU vs unit API | detection at all | ⬜ | |

## E. Boss sources (§6 — sourcing, not detection)

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| E1 | BigWigs is present & its message bus fires | `BigWigs` global / `RegisterMessage("BigWigs_StartBar")` | boss source #1 | ✅ | `BigWigs`, `BigWigsLoader`, `IsAddOnLoaded("BigWigs")` all present (probe, Kings' Rest). Message-bus fire still to confirm on a pull. |
| E2 | A **public Blizzard boss-mod API** exists | probe `C_*` globals (`C_EncounterInfo`?, boss-mod namespace) | boss source #2 (else dropped) | ❌ | `C_EncounterInfo` nil; **no** `*BossMod*`/`*EncounterMod*`/`C_BossMod` global found. No discoverable public built-in boss-mod API by name → boss source #2 deferred; BigWigs is the boss source. |
| E3 | `ENCOUNTER_START/END`, `BOSS_KILL` fire | events | pull/wipe framing | ⬜ | not yet tested (no boss pulled during probe) |
| E4 | Read encounter timeline from Encounter Journal | `EJ_*` / `C_EncounterJournal` | timeline without a boss mod | ⚠️ | `C_EncounterJournal` present, but it's static journal data, not live timings. Not a boss-timer source on its own. |

## F. Nameplates & units

| # | Capability we need | API we'd use | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| F1 | Enemy nameplates enumerable | `C_NamePlate.GetNamePlates` | GUID↔unit mapping | ⬜ | needs nameplates on |
| F2 | `NAME_PLATE_UNIT_ADDED/REMOVED` fire in M+ | events | live caster tracking | ⬜ | |
| F3 | Read a nameplate unit's cast in real time | `UNIT_SPELLCAST_START` (unit) | second detection path | ⬜ | vs CLEU only |

## G. Cost / feasibility

| # | Capability we need | Concern | Design depends on it | Status | Notes / result |
|---|---|---|---|---|---|
| G1 | CLEU volume in a big pull is handleable | perf | usability | ⬜ | events/sec in a real key |
| G2 | GUID↔nameplate scans cheap enough | perf | target resolution | ⬜ | |

---

## Test protocol

Verification happens in three escalating settings; capture with the probe
(§Probe) and record results in the tables above.

1. **Out of combat / target dummy (solo).** Establishes the *baseline* — most
   values are readable here, so this isolates what breaks specifically in combat
   / instances. Confirms A1–A5, C1, F1, E1/E2 existence checks.
2. **Solo old dungeon (non-M+).** Combat + instance behavior without M+ scaling:
   D1–D3 (what goes secret in combat), B1–B5 (target resolution on real casts),
   C3, F2–F3.
3. **A real Mythic+ key.** Volume and scaling truth: G1–G2, and confirms the
   above hold under load. This is where "does the relevance model tame the
   firehose" first gets a gut-check.

For each row: note the actual value seen, whether it was secret, and which
source (CLEU vs unit API) gave the cleaner read.

## Probe

The testing instrument is a **minimal probe addon** (not the full debug window):
a small standalone addon that, on a slash command and via passive logging,
answers the rows above — dumps enemy casts with every candidate target field,
flags which reads are secret, enumerates boss-mod globals, and reports CLEU
volume. It's throwaway/diagnostic; the real `Debug.lua` comes later, informed by
what the probe finds.

*(Probe not built yet — see roadmap Phase 1. This file is the spec for what it
must measure.)*

---

## How results feed back

- **B3 ❌ + B1 mostly ❌** → "targeted" alerts must key off debuffs (B4), not
  casts. Rewrite design §3 targeted path and §7.1.
- **E2 ❌** → drop Blizzard boss source; BigWigs becomes the only boss source,
  and "no hard dependency" gets an asterisk for boss timelines.
- **D1 shows casts go secret in combat** → detection floor is threatened;
  re-evaluate whether the whole approach is viable or must lean on boss sources.
- **G1 too high** → need aggressive pre-filtering at the CLEU boundary before
  events reach Relevance.

Nothing gets built on a ⬜.
