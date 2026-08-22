# Alerter — Design

A standalone Mythic+ / encounter **alerting** addon for WoW 12.1. Spiritual
successor to Causese's WeakAura pack — reproducing what it *did* (surface the
dangerous mechanic, to the right person, at the right moment, with a clean
visual + sound) without the WeakAuras engine underneath, and without inheriting
its biggest weakness: a hand-curated spell database that rots every patch.

Style and conventions are inherited from **PRIO** (the author's rotation addon)
so the two feel like one family of addons.

---

## 1. What we're replacing, and why

Causese's system is really three addons:

- **`CauseseDB`** — `db.lua`, a hand-curated Mythic+ spell knowledge base
  (targeted / trash-interrupt / predictive-timers / tank-buster), plus
  `functions.lua`, glue that reaches *into* WeakAuras to position regions.
- **`SharedMedia_Causese`** — 200+ voice/sound cues.
- **The Wago WeakAura** — mostly a display shell whose custom triggers read
  `CauseseDB` and route displays into named dynamic groups.

The intelligence lived in the **data**, not the aura. That data model is a good
map of *which categories of mechanic matter*, but the specific spell list is
perpetually out of date and is a maintenance treadmill. **Alerter keeps the
taxonomy and throws away the treadmill.**

### Design stance

- **Detection over curation.** The game already fires a reliable event for
  every enemy cast and aura. "Which casts matter" is largely *derivable* from
  cast metadata (interruptible flag, whether it targets a player, cast time,
  source), so the foundation is a rules-based classifier — not a spell list.
- **A curated layer is an optional override, never the foundation.** Labels,
  sounds, and "this one is genuinely lethal" tuning sit *on top* of detection.
  If curation goes stale, detection still works.
- **Boss data comes from a swappable provider**, so we can run — and compare —
  Blizzard's built-in boss mod vs. BigWigs.
- **Secret-value-safe throughout**, per 12.1 API rules (see PRIO's `API.lua`).

---

## 2. Architecture

```
  ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐
  │  DETECTION   │──▶│    CLASSIFY      │──▶│    DISPLAY     │
  │ combat log   │   │ interruptible?   │   │ icons / bars / │
  │ UNIT_SPELL*  │   │ targets a player?│   │ text / sound   │
  │ UNIT_AURA    │   │ AoE / tank-buster│   │ (channels)     │
  │ boss provider│   │ role filter      │   └────────────────┘
  └──────────────┘   │ + curated override│
        ▲            └──────────────────┘
        │
  ┌─────┴───────────────────────┐
  │  Boss provider interface     │
  │  Blizzard | BigWigs | (DBM)  │
  └──────────────────────────────┘
```

Detection normalizes everything (raw combat log, cast events, and each boss
provider) into **one event shape**. Classify and Display never know or care
where an event came from — only its normalized fields and its `provider` tag.

### Module map (PRIO-styled)

| File | Responsibility |
|---|---|
| `Alerter.toc` | `## Interface: 120100`, `## SavedVariables: AlerterDB` |
| `Core.lua` | namespace bootstrap, `On()` event dispatcher, saved vars, ticker, slash command |
| `API.lua` | secret-safe wrappers: cast info, auras, unit/GUID, spell info |
| `UI.lua` | `Window / Font / Solid / C` palette, class-color accent (lifted from PRIO) |
| `Detect.lua` | subscribes to CLEU + `UNIT_SPELLCAST_*` + `UNIT_AURA`, emits normalized events |
| `Providers/Blizzard.lua` | boss provider #1 — Blizzard built-in boss mod |
| `Providers/BigWigs.lua` | boss provider #2 — BigWigs message bus *(later)* |
| `Classify.lua` | rules-based category assignment + curated overrides + role/target filter |
| `Debug.lua` | the detection window: provider-tagged, filterable live event log |
| `Display.lua` | native render (icon/bar/text/sound) into channels *(after debug proves detection)* |
| `Options.lua` | settings, provider toggle, profiles/presets |
| `Minimap.lua` | minimap button (lifted from PRIO) |

Inherited PRIO patterns: `local ADDON, Alerter = ...` + `_G.Alerter`; the tiny
`Alerter:On(event, fn)` dispatcher with per-handler `pcall`; `DeepFill` defaults
with named profiles and one-click presets; a `C_Timer` ticker; secret-safe reads
that fail open.

---

## 3. Normalized event schema

Every source produces events of this shape. This is the contract between
Detection/Providers and everything downstream.

```lua
event = {
    -- identity
    kind        = "cast" | "aura" | "bosstimer" | "bossmsg",
    spellID     = 448248,
    name        = "Revolting Volley",

    -- provenance (drives the debug diff + provider toggle)
    provider    = "cleu" | "unitcast" | "blizzard" | "bigwigs",
    subEvent    = "SPELL_CAST_START",       -- raw sub-event, when applicable

    -- actors
    sourceGUID  = "Creature-...",
    sourceName  = "Bloodstained Webmage",
    sourceUnit  = "nameplate7",             -- if resolvable
    destGUID    = "Player-...",             -- target of the cast/aura, if any
    destName    = "Healbot",
    destIsPlayer= true,
    destIsMe    = false,

    -- timing
    castTime    = 3.0,                       -- seconds, if a cast/channel
    expiration  = 12345.6,                   -- GetTime()-based, if timed
    timeLeft    = 4.2,                        -- for provider bars

    -- flags read at emit time
    interruptible = true,                    -- not-interruptible inverted
    channel     = false,
}
```

Classify **enriches** the event in place, adding:

```lua
    category   = "interrupt" | "targeted" | "aoe" | "tankbuster" | "info",
    priority   = 0..4,                       -- higher = louder / bigger
    role       = "ALL" | "TANK" | "HEALER" | "DPS",
    label      = "Volley",                   -- short display label (override or derived)
    sound      = "…",                        -- LSM key, optional
    channel    = "TrashTimer" | "CC" | "TankBar" | "Important" | …,
}
```

---

## 4. Boss provider interface

A provider is a table registered with Detection. It translates its native
events into the normalized shape and pushes them via `Detect:Emit(event)`.

```lua
Provider = {
    id        = "blizzard",         -- matches event.provider
    label     = "Blizzard boss mod",
    Available = function() -> bool end,   -- is this source usable right now?
    Enable    = function(self) end,       -- hook native events, start emitting
    Disable   = function(self) end,       -- unhook
}
Alerter.Detect:RegisterProvider(Provider)
```

- **Blizzard.lua** consumes the built-in boss-mod events (the same hook style
  used for the Cooldown Manager in PRIO). Default, no third-party dependency.
- **BigWigs.lua** listens to BigWigs' message bus (`BigWigs_StartBar`, etc.),
  translating bars/messages into `bosstimer` / `bossmsg` events. Only
  `Available()` when BigWigs is loaded.

**Comparison mode:** more than one provider may be enabled at once. Every event
carries its `provider`, so the debug window can show Blizzard and BigWigs side
by side — do timings agree? does one miss a pull? which resolves targets? This
is how we *decide* which to trust, rather than guessing.

---

## 5. Detection model

### Bosses — a plumbing problem, not a detection problem
The provider gives us the timer/ability directly. Restyle into a channel. Done.

### Trash — the real problem, split in two

1. **Detection** (does the event fire?) — *solved by the game.* Every enemy
   cast fires `SPELL_CAST_START` / `SPELL_CAST_SUCCESS` in CLEU, and
   `UNIT_SPELLCAST_START` on nameplate units. 100% reliable. The open question
   is only *which event carries reliable source + target + interruptible in
   12.1* — that's what the debug window will answer live.

2. **Classification** (which casts matter, and what kind?) — a rules pass over
   metadata, **no curated list required for a first cut**:

   | Signal at cast time | Inferred category |
   |---|---|
   | `notInterruptible == false` | **interrupt** (priority by cast time) |
   | dest is a party/raid member | **targeted** → show *who* |
   | no player dest / area effect | **aoe / soak** |
   | source is on the tank, frontal-ish | **tankbuster** candidate |
   | long cast / channel | render as a **bar** vs. instant flash |

   A **curated override table** (keyed by spellID) can refine any of these:
   nicer label, specific sound, force priority, suppress noise. Overrides are
   additive and optional — detection degrades gracefully without them.

### Target resolution (the hard 12.1 detail)
Knowing *who* a cast targets is the crux of "targeted" alerts. Candidate
signals, to be validated in the debug window:
- CLEU `destGUID` on `SPELL_CAST_SUCCESS` (present for some spells).
- `UnitCastingInfo` on the caster's nameplate unit + `UnitGUID` cross-ref.
- Debuff application: `SPELL_AURA_APPLIED` with `destGUID` = the target.
The debug window logs all three per event so we learn the reliable path per
mechanic type before Display is built.

---

## 6. The debug window (first deliverable)

Mirrors PRIO's `Debug.lua` skeleton (pooled rows, `OnUpdate` throttle, context
rebuild) but is a **live, scrolling, provider-tagged event log** — the
instrument we use in a real key to validate detection *and* diff providers.

Per row:
`time · provider · subEvent · spellID · name · source · resolved-target ·
interruptible? · castTime · inferred-category`

Controls:
- **Filters:** by provider, by category, interruptible-only, has-player-target,
  hide-friendly.
- **Freeze / scroll** so it's usable mid-pull.
- **Copy/export** the captured stream (feeds any future curated override table).

It doubles as a capture tool: run a dungeon → simultaneously prove detection and
generate raw data we could curate from later, if we choose to.

---

## 7. Saved variables

`AlerterDB`, PRIO-style: `DeepFill` over defaults, named **profiles**,
one-click **presets**, `defaultsRevision` migration prompt. Reserved keys:
provider selection + comparison toggle, per-category enable/priority, per-role
filtering, display channel layout, and the optional `overrides` table.

---

## 8. Roadmap

- **Phase 0 — Shell.** Loadable addon: `Core / API / UI / Alerter.toc`, slash
  command, saved vars. Confirms it loads clean on 12.1.
- **Phase 1 — Detection + debug window.** `Detect.lua` emitting normalized
  events from CLEU + `UNIT_SPELLCAST_*` + `UNIT_AURA`; the provider-tagged debug
  window. *Goal: watch real detection in a key and answer the target-resolution
  question.*
- **Phase 2 — Providers.** Blizzard boss provider first; BigWigs provider second;
  comparison mode in the debug window.
- **Phase 3 — Classifier.** Rules-based categorization validated against captured
  data; optional curated override layer.
- **Phase 4 — Display.** Native render into channels (icon/bar/text/sound),
  reusing PRIO's UI toolkit and LSM for media.
- **Phase 5 — Options / profiles / presets.** Full configuration surface.

---

## 9. Explicitly out of scope (for now)
- Porting Causese's `db.lua` spell list verbatim (rots; reference only).
- Requiring WeakAuras or any third-party addon at runtime (BigWigs is optional).
- Raid-wide encounter scripting beyond what a provider already supplies.
