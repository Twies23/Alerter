# Alerter — Handoff

Full context for picking this up in local dev. Alerter is a planned standalone
WoW **12.1 (Midnight)** Mythic+/encounter **alerting** addon — a spiritual
successor to Causese's WeakAura pack (and a lighter alternative to the M33kAuras
/ Yukero dungeon pack), built native instead of on the WeakAuras engine.

This session was **design discovery + research only**. No addon code exists yet
except a throwaway probe. Nothing is verified against a live client.

---

## TL;DR of where we are

- **Design is a documented wishlist**, not validated. See `DESIGN.md` (read
  §0 first — it's explicitly aspirational).
- **The big research result:** a currently-shipping Midnight pack (Yukero's, 281
  auras, decoded this session) detects mechanics with **only** BigWigs/DBM boss
  timers (203 triggers) + **auras on the player** (86, via `UNIT_AURA`). **Zero
  combat-log enemy-cast scraping.** That plus the Wowhead reporting that Midnight
  keeps "computation firmly in the past" means: **build detection on BossMod
  events + player/party auras, not combat-log cast classification.**
- **Consequence:** the `AlerterProbe` addon was built to test combat-log
  trash-cast detection and has an unresolved `captured 0` bug — but that premise
  is now suspect. Don't sink time into that bug; re-point the probe (see Next
  steps).
- **Boss timing = BigWigs** (confirmed present in 12.1). No public Blizzard
  built-in boss-mod API exists (`C_EncounterInfo` nil) — that idea is dead.

---

## Repo contents

| Path | What it is |
|---|---|
| `DESIGN.md` | The wishlist design: thesis (relevance > detection), the 4-intent model (On me / Stop it / Group react / Timeline), architecture, provisional event schema, boss-source interface, roadmap. **Still leads with combat-log detection — needs revising per the ground truth (see Next steps #1).** |
| `CAPABILITIES.md` | Verification matrix (§A–H). Every observability the design needs, how to test it, and what breaks if it's missing. Only the E-rows (boss sources) are filled in so far. **§H (can we even compute in combat?) is the key risk.** |
| `RESEARCH.md` | Prior-art + ecosystem notes (Causese, M33kAuras source, Yukero pack) and the decoded-pack **detection ground truth**. Read the "Decoded Yukero pack — detection breakdown (GROUND TRUTH)" section — it's the most important finding. |
| `AlerterProbe/` | Throwaway diagnostic addon (does not alert). Logs enemy trash casts + target/interrupt/secret fields. Has a `captured 0` bug and, per the research, tests the wrong premise. Keep for reference; repurpose per Next steps. |
| `tools/decode_wa.py` | Pure-stdlib Python decoder for `!WA:2!` WeakAuras strings (EncodeForPrint → raw DEFLATE → LibSerialize). Ported from LibDeflate/LibSerialize. Usage: `python3 tools/decode_wa.py wa.txt` → writes `wa_decoded.json`. |

**Not in the repo (deliberately):** the raw Yukero import string and its decoded
`wa_decoded.json` (~1 MB) — that's a third party's pack; we don't redistribute
it. Regenerate locally if you want it for reference (paste the string into a
file, run the decoder). It was decoded this session purely to study technique.

---

## Key decisions made (and why)

1. **Standalone native addon, not a WeakAuras fork.** WeakAuras is EOL in
   Midnight; M33kAuras (the fork) is heavy and "never really caught on." Alerter
   wins by being small and opinionated. Inherit conventions from the author's
   **PRIO** addon (namespace bootstrap, `On()` event dispatcher, secret-safe API
   wrappers, saved-vars/profiles, UI toolkit).
2. **Not bolted to Causese.** Its `db.lua` static spell list rots every patch;
   reference only. Alerter's model is action-based intents + a relevance filter.
3. **Detection is easy, relevance is the whole problem** — was the thesis. The
   research refines it: relevance still matters, but the *raw material* is
   BossMod events + player auras, not classified casts.
4. **Boss data via a provider interface**, BigWigs first (contract captured in
   `DESIGN.md` §6 from the M33kAuras `BossMods.lua` bridge), DBM second, Blizzard
   built-in dropped (no API).
5. **Everything is unverified.** `CAPABILITIES.md` is the ledger; nothing
   graduates to a dependency until tested on a live client.

---

## Open questions (test these first in local dev / in-game)

From `CAPABILITIES.md`, the ones that now matter most:
- **§H1 — can we branch on read values in combat, or does taint/secret block
  it?** This decides whether the relevance model is even possible. If not, retreat
  to display-side customization + boss-mod timing.
- **§B/C — confirm "targeted/on me" mechanics surface as player auras**
  (`UNIT_AURA`, mostly HELPFUL markers), as the decoded pack implies.
- **§E1 — BigWigs message bus actually fires** on a pull (present confirmed;
  live fire not yet).

---

## Suggested next steps (in order)

1. **Revise `DESIGN.md`** so the detection model leads with **BossMod events +
   player/party `UNIT_AURA`**, and demotes combat-log cast detection to an
   optional experiment. (The doc still leads with the old combat-log-first model.)
2. **Re-point `AlerterProbe`** (or write a fresh probe) to the proven model:
   subscribe to BigWigs `BossMod_*`-style messages and log player/party
   `UNIT_AURA` applications with secret-value flags. This also answers §H1.
   Don't chase the old `captured 0` combat-log bug.
3. **Scaffold the addon shell** (Phase 0): `Alerter.toc` (`## Interface: 120100`,
   `## SavedVariables: AlerterDB`), `Core.lua` (namespace + `On()` dispatcher +
   ticker + slash cmd), `API.lua` (secret-safe wrappers), `UI.lua` — all in the
   PRIO style. Then Detect → Relevance → Display per the roadmap.

---

## Local dev setup

**Repo**
```
git clone -b claude/weak-aura-addon-design-oc7eaj https://github.com/Twies23/Alerter
cd Alerter
```
Active branch: `claude/weak-aura-addon-design-oc7eaj` (all work is here; no PR
opened). Default branch was empty at session start.

**Testing the probe in WoW**
- Copy `AlerterProbe/` into `World of Warcraft/_retail_/Interface/AddOns/`.
- Enable it, enter world, `/aprobe` opens the window. Enemy nameplates on.
- (Known: `captured 0`; the instrumented header shows `cleu/cast/npc` counters +
  any `ERR:`. But per the research, prefer building the aura/BossMod probe instead.)

**Reference addons (not in this repo — clone separately if useful)**
- `Twies23/PRIO` — the author's rotation addon; the house style to mirror.
- `m33shoq/M33kAuras` — WeakAuras fork; study `M33kAuras/BossMods.lua`
  (BigWigs/DBM → normalized `BossMod_*` events) and `TimelineParser.lua`.
- `SafeteeWoW/LibDeflate`, `rossnichols/LibSerialize` — decoder references.

**Lua lint:** `luac5.1 -p <file>` (WoW runs Lua 5.1). Consider adding a
SessionStart hook / luacheck config for CI.

**Tooling note:** `tools/decode_wa.py` needs only Python 3 stdlib. To inspect any
`!WA:2!` export: save it to `wa.txt`, run `python3 tools/decode_wa.py wa.txt`.

---

## Environment notes from this session
- Ran in Claude Code on the web (ephemeral cloud container) — could not reach a
  local WoW install, so nothing was tested in-game.
- Network egress is filtered: GitHub git clones work; `wowhead.com` and `wago.io`
  are blocked (that's why article/pack came in as pasted text/PDFs).
- The full decoded pack JSON and raw string live only in the session scratchpad
  (not committed); regenerate with the decoder if needed.
