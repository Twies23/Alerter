# Alerter — Prior-art & ecosystem research

Notes from studying existing dungeon-alert packs and the Midnight addon
landscape. Reference only — Alerter is not bound to any of these (see DESIGN §0).

## Sources
- **Causese addons** (prior): `CauseseDB` (`db.lua` curated M+ spell tables),
  `SharedMedia_Causese` (200+ voice cues). The static-curation model.
- **M33kAuras** (m33shoq, GitHub): an open-source WeakAuras *fork*. Studied
  `BossMods.lua` (DBM/BigWigs → normalized `BossMod_*` events) and
  `TimelineParser.lua` (data-driven authored timelines). Folded into DESIGN §6.
- **Midnight S2 Dungeon Pack by Yukero** (Wago, runs on M33kAuras): the current
  competitor. Its raw import string was **not recoverable** (only available as a
  print-to-PDF with truncated, font-subset-encoded text). The wago page itself
  yielded nothing readable.
- **Wowhead article** (Archimtiros, 2026-08-23): the substantive find.

## Key ecosystem findings (from the Wowhead article)

1. **WeakAuras is EOL in Midnight.** It "famously announced it was ceasing
   development due to the addon API changes in Midnight." M33kAuras is the
   open-source offshoot that continued it — **"with much more limited
   functionality, due to all of the new addon restrictions."**
2. **Midnight restricts computation, not just reads.** Blizzard "has since eased
   up on some of those restrictions, allowing more information to be
   manipulated, though focusing more on visual customization, **while still
   keeping full control and computation firmly in the past**." → The concession
   was *visual customization only*; computation-heavy addons appear to be gone by
   design. That is exactly the surface our relevance model lives on — treat it as
   a hard constraint, not a temporary restriction.
3. **Packs depend on a boss mod for encounter timers.** "Users will still need
   to ensure they also have their favorite boss mod installed … since these
   auras rely on their encounter timer information." Confirms E1 (BigWigs/DBM is
   the boss-timing source); there is no native encounter-timer API.
4. **Feature table-stakes:** per-warning **anchor positioning** and **voice /
   sound cues** ("many vocal warnings for auditory gamers"), with a WA-style
   customization UI. Same shape as Causese.
5. **These packs "never really caught on with high-end players"** in Midnight —
   "the encounters just didn't need them as much as WeakAuras of the past."
   Comparable to Northern Sky Raid Tools, DBM, BigWigs.

## Yukero pack — confirmed specifics (from the wago page)

- Version `v1.0.11`, `[12.1.0 - Midnight]`, 39 stars — current, modest adoption.
- **Reuses Causese's sound library.** Requires **both** `SharedMedia_Causese`
  *and* `yukero-shared-media` for "the full sound experience." → Causese's voice
  cues are the community-standard dungeon-alert sound set; matching those LSM
  sound names would make Alerter instantly familiar.
- **Hard deps:** BigWigs *or* DBM (boss timer data) + the M33kAuras engine.
- **Customization model:** an "Anchors folder" of movable icons/bars the user
  drags to fit their UI. Anchor-based positioning is the expected baseline.

## Implications for Alerter

- **Opportunity.** WeakAuras is dead and its forks are limited/janky. A lean,
  purpose-built native alerter has a clear gap to fill — *if* it does the few
  things players actually need well, rather than being a general engine.
- **New top risk: the computation clampdown (finding #2).** Our differentiator —
  the relevance model (role × spec × capability filtering, promotion) — is
  precisely the "computation / information manipulation" Midnight restricts. We
  must verify what filtering logic is even *permitted* on the values we can read,
  not just what's readable. This raises the stakes on the D-rows (secret values)
  and adds CAPABILITIES §H. If heavy client-side relevance logic is disallowed,
  the design pivots toward simpler, display-side customization (where Blizzard
  explicitly left room) plus boss-mod-sourced timing.
- **Boss timing = BigWigs/DBM, settled.** No native encounter API (reconfirms
  E1/E2). Build the BigWigs source; treat a boss mod as a soft dependency for
  encounters (trash detection stays ours via combat log).
- **Ship the table stakes.** Anchored, positionable warnings + sound/voice cues
  are expected baseline, not nice-to-haves.
- **Don't rebuild an engine.** M33kAuras' lesson: a full WA fork is heavy and
  didn't win players. Alerter wins by being small and opinionated, not by
  matching WeakAuras feature-for-feature.
