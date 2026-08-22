# Alerter — Design

A standalone Mythic+ / encounter **alerting** addon for WoW 12.1.

The itch it scratches is a UX one: the clean, at-a-glance "here's the dangerous
thing, react *now*" feedback that Causese's WeakAura pack gave in dungeons —
without running the WeakAuras engine, and without inheriting a hand-curated spell
list that rots every patch. Causese is the inspiration for the *feel*, not a
spec to reproduce. We're free to be original.

Conventions are inherited from **PRIO** (the author's rotation addon) so the two
feel like one family.

---

## 1. The real problem

It is tempting to frame this as a detection problem. It isn't.

- **Detection is easy.** The game reliably fires an event for every enemy cast
  and aura. Getting "something is being cast" is trivial.
- **Relevance is the whole problem.** Which of the hundreds of casts per dungeon
  are *worth interrupting your attention for*, and *for whom*? That is the hard,
  interesting question — and the one that determines whether the addon is useful
  or just noise.

Two failed answers bound the space:

- **Static curation (Causese's model).** Accurate but a maintenance treadmill;
  every patch it drifts out of date.
- **Naive heuristics** ("alert on every interruptible cast"). Zero maintenance
  but a firehose — most interruptible casts don't matter, and several lethal
  mechanics have no cast to detect at all.

**Alerter's bet is a third answer: a relevance model.** Show only what is
*actionable for you*, and make "what matters" emergent and shareable rather than
hand-maintained by one person.

---

## 2. Principles

- **Actionability over completeness.** A good alert implies a response you can
  make *right now* (kick this, move from this, this is on you). If there's no
  action, it's not an alert — at most it's ambient info.
- **Personal relevance is a first-class filter.** Role, spec, and current
  capability (do I even have an interrupt available?) decide what surfaces —
  not just what's being cast.
- **Emergent "what matters," not a curated treadmill.** The addon captures what
  it sees; the set of *promoted* alerts grows from play (personal, and
  optionally shared packs) instead of one maintainer's list.
- **Secret-value-safe throughout**, per 12.1 API rules (see PRIO's `API.lua`):
  every read `pcall`-guarded, `issecretvalue`-checked, failing *open*.
- **No hard third-party dependency.** BigWigs is optional; nothing is required
  at runtime.
- **Earn each layer with evidence.** We do not build the classifier or the
  display until the debug window has shown us what detection actually yields in
  a live key. Assumptions get verified before they get code.

---

## 3. Alerter's own model (not Causese's channels)

Rather than port Causese's 13 display groups, we define alerts by **what the
player must do**, from first principles:

| Intent | Question it answers | Typical response |
|---|---|---|
| **On me** | Is a mechanic targeting *me*? | move / turn / use personal |
| **Stop it** | Is there a cast I should interrupt/CC? | kick / stun — *only if I can* |
| **Group react** | Something everyone must respond to | spread / stack / soak / dodge |
| **Timeline** | What's coming from the boss, and when | pre-position |

These intents are the stable vocabulary. How they render (icon, bar, text,
sound, edge flash) is a display concern layered on top, configurable — not
baked into the model. This is deliberately *not* Causese's taxonomy; it's
organized around player action, which is what makes an alert feel earned.

The **relevance filter** sits between "detected" and "shown":
`role × spec × capability × user/pack promotion`. An interruptible cast only
becomes a "Stop it" alert if you have a kick and this cast has been promoted as
worth kicking; a "targeted" mechanic on you is always shown. This filter is the
heart of the addon.

---

## 4. Architecture

```
  ┌──────────────┐   ┌───────────────────┐   ┌────────────────┐
  │  DETECTION   │──▶│  RELEVANCE        │──▶│    DISPLAY     │
  │ combat log   │   │  role/spec/cap    │   │ intents render │
  │ UNIT_SPELL*  │   │  + promotion set  │   │ as icon/bar/   │
  │ UNIT_AURA    │   │  + heuristic hints│   │ text/sound     │
  │ boss source  │   └───────────────────┘   └────────────────┘
  └──────────────┘             ▲
        ▲                      │
        │              ┌───────┴─────────┐
  ┌─────┴──────────┐   │ Promotion store │  personal + optional
  │ boss source(s) │   │ (what matters)  │  shared packs
  │ (see §6)       │   └─────────────────┘
  └────────────────┘
```

Detection normalizes every source into one provisional event shape (§5).
Relevance decides whether — and as which intent — an event surfaces. Display
renders intents. Nothing downstream cares where an event came from beyond its
`source` tag.

### Module map (PRIO-styled)

| File | Responsibility |
|---|---|
| `Alerter.toc` | `## Interface: 120100`, `## SavedVariables: AlerterDB` |
| `Core.lua` | namespace, `On()` event dispatcher, saved vars, ticker, slash cmd |
| `API.lua` | secret-safe wrappers: cast info, auras, unit/GUID, spell info |
| `UI.lua` | `Window / Font / Solid / C` palette, class-color accent (from PRIO) |
| `Detect.lua` | CLEU + `UNIT_SPELLCAST_*` + `UNIT_AURA` → normalized events |
| `Relevance.lua` | role/spec/capability filter + promotion lookup + heuristic hints |
| `Debug.lua` | the detection window: source-tagged, filterable live event log |
| `Display.lua` | render intents (icon/bar/text/sound) *(built after debug)* |
| `Options.lua` | settings, promotion management, profiles/presets |
| `Minimap.lua` | minimap button (from PRIO) |

Inherited PRIO patterns: `local ADDON, Alerter = ...` + `_G.Alerter`; the tiny
`Alerter:On(event, fn)` dispatcher with per-handler `pcall`; `DeepFill`
defaults with named profiles and presets; a `C_Timer` ticker; secret-safe reads
that fail open.

---

## 5. Event schema — provisional

This is a *starting* shape, not a contract. Phase 1 will add/remove fields based
on what the debug window shows is actually available in 12.1. Fields we're
unsure survive real conditions are marked ⚠.

```lua
event = {
    kind        = "cast" | "aura" | "boss",
    spellID     = 448248,
    name        = "Revolting Volley",
    source      = "cleu" | "unitcast" | "boss:<provider>",   -- provenance
    subEvent    = "SPELL_CAST_START",

    sourceGUID  = "Creature-...",
    sourceName  = "...",
    sourceUnit  = "nameplate7",          -- ⚠ not always resolvable
    destGUID    = "Player-...",          -- ⚠ often absent on casts (see §7)
    destIsMe    = false,                 -- ⚠ depends on destGUID
    castTime    = 3.0,
    interruptible = true,                -- ⚠ readable at emit time?
}
```

Relevance enriches surviving events with `intent`, `priority`, `label`,
`sound`, and `render` hints. We define those precisely only once the base fields
are proven.

---

## 6. Boss data — a source behind a small interface

Bosses are a *sourcing* question, not a detection one: something authoritative
already knows the timeline; we consume and restyle it. To keep options open
(and to satisfy the "BigWigs vs. non-BigWigs" comparison the author wants), boss
data comes through a thin interface with interchangeable implementations:

```lua
Source = {
    id = "bigwigs", label = "BigWigs",
    Available = function() -> bool end,
    Enable    = function(self) end,   -- hook native events, emit boss events
    Disable   = function(self) end,
}
```

Planned implementations, **in confidence order**:

1. **BigWigs** — has a real, documented message bus (`BigWigs_StartBar`, …).
   Lowest-risk source; build first.
2. **Blizzard built-in boss mod** — *only if it exposes a public, hookable API.*
   This is unverified (§7). If it's UI-only, this source is deferred or dropped.

More than one source may run at once; every event keeps its `source` tag so the
debug window can diff them (do timings agree? does one miss a pull?). That
comparison is a *diagnostic*, not a core feature we over-invest in.

> Note: this reorders the earlier plan. Blizzard-first was an assumption; until
> its API is confirmed, BigWigs is the safer first target.

---

## 7. Open questions the debug window must answer

These were previously stated as facts. They are actually the reason Phase 1
exists — we resolve them by observation before building on them.

1. **Cast target resolution.** How do we reliably learn *who* an enemy cast
   targets in 12.1? Candidate signals to log side-by-side:
   - CLEU `destGUID` on `SPELL_CAST_SUCCESS` (present for *some* spells only),
   - `UnitCastingInfo` on the caster's nameplate unit + GUID cross-ref,
   - debuff application `SPELL_AURA_APPLIED` with `destGUID` = target.
   Likely the answer is *per-mechanic*, and some "targeted" alerts must key off
   the resulting debuff, not the cast.
2. **Interruptible flag availability.** Is `notInterruptible` reliably readable
   at `SPELL_CAST_START` for enemy casts, or must we read it from the nameplate
   unit?
3. **Instant / no-cast mechanics.** Lethal mechanics with no cast bar can only
   be caught via aura application or CLEU damage/aura events. How much of the
   "what matters" set is instant?
4. **Blizzard boss-mod API.** Does 12.1's built-in boss mod expose a public,
   consumable event API (à la `C_CooldownViewer`), or is it UI-only? Determines
   whether §6 source #2 is viable.
5. **Combat-log completeness in instances.** Any throttling / secret-value
   restrictions on enemy cast events inside M+ that affect reliability.

The debug window logs the raw material for all five at once.

---

## 8. The debug window (first real deliverable)

Mirrors PRIO's `Debug.lua` skeleton (pooled rows, `OnUpdate` throttle, context
rebuild) but is a **live, scrolling, source-tagged event log** — the instrument
we run in a real key to answer §7 and to seed the promotion store.

Per row: `time · source · subEvent · spellID · name · caster · resolved-target
(+ how) · interruptible? · castTime`.

Controls: filter by source / kind / interruptible / has-player-target /
hide-friendly; **freeze & scroll** for mid-pull use; **copy/export** the stream.

It doubles as the **capture tool**: run a dungeon → prove detection *and*
generate the raw data from which alerts get promoted.

---

## 9. Relevance & the promotion store

The durable answer to the rot problem:

- **Capture** — Detect sees everything; the debug window records it.
- **Promote** — a spellID becomes an alert (with intent, label, sound) when
  promoted: by the user (one click from the debug log or options), or by an
  imported **pack** (a shareable promotion set — this is how community curation
  happens without a single maintainer's treadmill baked into the addon).
- **Filter** — at runtime, a promoted alert only *fires* when it passes
  `role × spec × capability`. Heuristic hints (interruptible? targets a player?)
  can *suggest* promotions in the UI, but never auto-fire — they fight the
  firehose by guiding curation, not by replacing it.

`AlerterDB` (PRIO-style `DeepFill` + profiles + presets) stores: enabled
sources & comparison toggle, per-intent display config, the promotion store,
and imported packs.

---

## 10. Roadmap

- **Phase 0 — Shell.** Loadable `Core / API / UI / Alerter.toc`, slash command,
  saved vars. Confirms clean load on 12.1.
- **Phase 1 — Detection + debug window.** Normalized events from CLEU +
  `UNIT_SPELLCAST_*` + `UNIT_AURA`; the source-tagged debug window. *Goal:
  answer every question in §7.*
- **Phase 2 — Boss source.** BigWigs source first; Blizzard source only if §7.4
  confirms an API. Comparison view in the debug window.
- **Phase 3 — Relevance + promotion.** The role/spec/capability filter, the
  promotion store, promote-from-debug, pack import.
- **Phase 4 — Display.** Render the four intents (icon/bar/text/sound/edge),
  reusing PRIO's UI toolkit and LSM for media.
- **Phase 5 — Options / profiles / presets / sharing.** Full config + pack
  export/import.

---

## 11. Explicitly out of scope (for now)
- Porting Causese's `db.lua` verbatim (rots; reference only, and we're not bolted
  to its taxonomy).
- Requiring WeakAuras or any addon at runtime (BigWigs optional).
- Auto-firing alerts purely from heuristics (they guide curation, not replace it).
- Raid-wide encounter scripting beyond what a boss source already supplies.
```
