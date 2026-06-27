---
name: wild-mode-skills
description: >
  Complete engineering guide for Wild Mode character skill implementation and debugging.
  Attach this skill when: adding a new skill or passive, debugging why a skill does not trigger,
  investigating why ui_hints is empty, tracing why a tier-2 passive is not activating, or any
  task that touches Python skill logic, Laravel SkillEffectService, or React Native skill components.
  Contains the full data-flow, file map, debug commands, common failure signatures, and
  implementation checklists. Eliminates guessing and prevents introducing new bugs.
argument-hint: 'skill_id or passive name, symptom description (e.g. "tier 2 not firing"), and the raw server logs if debugging'
---

# Wild Mode Skills Engineering Guide

## 0. Read This First — How To Not Guess

The #1 source of bugs in this codebase is making a fix in one layer without knowing what the
other layers expect. Before writing a single line:

1. **Run the registration checker** — catches 80% of issues in 30 seconds.
2. **Read the debug logs** — the PHP and Python structured logs tell you exactly what was
   sent and received.
3. **Use the in-app debugger** — the SkillDebugScreen shows every `process_turn` call live.
4. **Check the reference implementation** — `spartan_guard.py` is the gold standard for
   passive + active + tier-2 patterns. Read it before writing a new skill class.

## 1. System Architecture

Three independent runtimes. Each has its own source of truth. Never duplicate logic across them.

```
React Native (Expo)          Laravel (PHP 8.2)           Python Engine (FastAPI)
─────────────────────        ─────────────────────        ─────────────────────────
Renders overlays             Normalizes active_skills     AUTHORITATIVE for:
Plays VFX/SFX                Persists metadata to DB      - Move validation
Handles touch input          Broadcasts via Socket.io     - Skill activation
Shows optimistic UI          Routes to Python             - State transitions
                             Applies HP damage            - FEN mutations
                                                          - Turn processing
                                                          - ui_hints generation
```

### Data Flow: Every Move

```
1. User drags piece           → CustomChessboardImpl.tsx
2. App sends move             → handleMove.ts → Laravel POST /api/games/{id}/move
3. Laravel validates move     → GameService.php
4. Laravel calls Python       → SkillEffectService.php POST /skill/process-turn
5. Python processes skills    → manager.py → skill_class.process_turn()
6. Python returns             → { ui_hints, events, updated_skills, fen_changed }
7. Laravel persists state     → game.metadata['active_skills']
8. Laravel broadcasts         → batched_update via Socket.io
9. App receives socket event  → useWildModeSkills.ts → onBatchedUpdateSkillEffects()
10. App renders               → SkillManager.tsx → skill component
```

### Data Flow: Skill Activation (Active Skills)

```
1. User taps skill button     → useCharacterSkills.ts
2. App fetches valid targets  → POST /skill/get-activation-options → Python
3. Python returns targets     → get_activation_options() in skill class
4. User selects target        → skill component (piece/zone/file selector)
5. App activates skill        → POST /api/games/{id}/skill/activate → Laravel
6. Laravel calls Python       → POST /skill/activate
7. Python validates + applies → validate() + apply() in skill class
8. Python returns new state   → { success, new_fen, active_skill_state }
9. Laravel persists + broadcasts
```

### Data Flow: Move Blocking (Passive Skills)

```
1. User drags piece
2. Laravel calls Python       → POST /skill/validate-move-with-skills
3. Python loops active skills → skill_class.blocks_move()
4. If blocked: { valid: false, blocked_by_skill, block_reason }
5. App rolls back optimistic move + shows alert
```

---

## 2. Complete File Map

Read this map before touching any file. Every surface that matters is listed here.

### Python Engine (Port 8095) — The Authority

| File | Purpose | Edit When |
|------|---------|-----------|
| [`app/skills/base.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/base.py) | BaseSkill ABC, all hooks, class constants reference | Never — read only |
| [`app/skills/registry.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/registry.py) | Auto-discovery singleton | Never — it discovers by import |
| [`app/skills/manager.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/manager.py) | Generic dispatcher: activation, turn processing, move blocking, charge tracking | Only if manager contract changes |
| [`app/routes/skills.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/routes/skills.py) | FastAPI endpoints: `/activate`, `/process-turn`, `/validate-move-with-skills`, `/debug-state` | Only if endpoint shape changes |
| [`app/skills/spartan_guard.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/spartan_guard.py) | **Reference implementation** — passive + active + tier-2 + discipline counter | Read before writing any new skill |
| `app/skills/{skill_id}.py` | Each skill's authoritative logic | When implementing/fixing that skill |
| [`app/skills/gate_ai_engine.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/gate_ai_engine.py) | Gate AI skill usage, enums, heuristics | When AI can cast the skill |
| [`app/skills/SKILLS.md`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/SKILLS.md) | Python-side architecture notes | After architectural changes |

**Templates** (copy these, do not invent from scratch):
- [`app/skills/templates/passive_template.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/templates/passive_template.py)
- [`app/skills/templates/triggered_template.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/templates/triggered_template.py)
- [`app/skills/templates/active_template.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/app/skills/templates/active_template.py)

### Laravel API (Port 8000) — The Bridge

| File | Purpose | Edit When |
|------|---------|-----------|
| [`app/Services/SkillEffectService.php`](file:///Users/zerakjamil/workspace/api/app/Services/SkillEffectService.php) | Normalizes skills → Python, persists state, applies HP, broadcasts | New state fields, tier handling, HP logic |
| [`app/Services/GateAIService.php`](file:///Users/zerakjamil/workspace/api/app/Services/GateAIService.php) | AI active-skill state → unified shape, move-blocking overlays | AI skill state or overlay changes |
| [`config/wild_skills.php`](file:///Users/zerakjamil/workspace/api/config/wild_skills.php) | Server-side metadata: unlock levels, tiers, interactions, charge mapping | New skill_id, tier rules, interaction rules |
| `config/character_skills.json` | Canonical `character_id → skill_id → charge_type → vfx_keys` map | New character or skill_id |

### React Native Frontend — The UI

| File | Purpose | Edit When |
|------|---------|-----------|
| [`src/config/abilities.ts`](file:///Users/zerakjamil/workspace/chess/src/config/abilities.ts) | `WILD_SKILLS`, `CHARACTER_WILD_SKILLS`, VFX keys, display names, derived helpers | Every new skill or character |
| [`src/config/skillDefinitions.ts`](file:///Users/zerakjamil/workspace/chess/src/config/skillDefinitions.ts) | `SKILL_IDS`, selection type, banner copy, backend param transforms | Every new skill_id |
| [`src/components/skills/registry.ts`](file:///Users/zerakjamil/workspace/chess/src/components/skills/registry.ts) | `SKILL_COMPONENT_REGISTRY`: skill_id → React component | New skill with custom UI component |
| [`src/hooks/useWildModeSkills.ts`](file:///Users/zerakjamil/workspace/chess/src/hooks/multiplayer/useWildModeSkills.ts) | Receives batched_update socket events, calls per-skill hooks | Socket event shape changes |
| [`src/services/skillEventDispatcher.ts`](file:///Users/zerakjamil/workspace/chess/src/services/skillEventDispatcher.ts) | Opponent activation/expiry overlays | New skill with remote visual state |
| [`src/hooks/useCharacterSkills.ts`](file:///Users/zerakjamil/workspace/chess/src/hooks/useCharacterSkills.ts) | Skill usage lifecycle: charges, modals, cutscenes, timelines | Lifecycle exceptions |
| [`src/hooks/skillActivationRegistry.ts`](file:///Users/zerakjamil/workspace/chess/src/hooks/skillActivationRegistry.ts) | Activation routing and completion side effects | Custom activation start or end |
| [`src/config/skillActivationConfig.ts`](file:///Users/zerakjamil/workspace/chess/src/config/skillActivationConfig.ts) | Character cut-in banners, activation flavor | Character has custom cut-in |
| [`src/config/skillTimelines/index.ts`](file:///Users/zerakjamil/workspace/chess/src/config/skillTimelines/index.ts) | Timeline-driven camera/SFX/VFX choreography | Skill has timeline effects |
| [`src/config/characters.ts`](file:///Users/zerakjamil/workspace/chess/src/config/characters.ts) | Character portraits, states, showcase images | New character |

**Per-skill component packages** (each in its own folder):
- [`src/components/skills/spartan-guard/`](file:///Users/zerakjamil/workspace/chess/src/components/skills/spartan-guard/)
- [`src/components/skills/golden-gambit/`](file:///Users/zerakjamil/workspace/chess/src/components/skills/golden-gambit/)
- [`src/components/skills/void-barrier/`](file:///Users/zerakjamil/workspace/chess/src/components/skills/void-barrier/)
- [`src/components/skills/frozen-files/`](file:///Users/zerakjamil/workspace/chess/src/components/skills/frozen-files/)
- `src/components/skills/{new-skill-kebab}/` ← create here

### Dev Tools

| File | Purpose |
|------|---------|
| [`scripts/check_skill_registration.py`](file:///Users/zerakjamil/workspace/api/python-chess-engine/scripts/check_skill_registration.py) | 6-layer registration checker — run first on any skill issue |
| [`chess/scripts/check_skill_frontend.sh`](file:///Users/zerakjamil/workspace/chess/scripts/check_skill_frontend.sh) | Frontend registration checker |
| [`src/screens/dev/SkillDebugScreen.tsx`](file:///Users/zerakjamil/workspace/chess/src/screens/dev/SkillDebugScreen.tsx) | In-app debugger — tap 🔬 in Skill Test Lab |
| `POST /skill/debug-state` | Python endpoint returning SkillTracer ring buffer |

---

## 3. BaseSkill Hook Reference

```python
class MySkill(BaseSkill):
    # ── Required class constants ──────────────────────────────────────────
    SKILL_ID = "my_skill"          # Must match filename and all registries
    SKILL_NAME = "My Skill"
    CATEGORIES = [SkillCategory.OFFENSIVE]
    CHARGE_TYPE = SkillChargeType.INSTANT   # or KILL_BASED / MOVE_BASED

    # ── Optional class constants ──────────────────────────────────────────
    DURATION_HALF_MOVES = 4        # How long it stays active
    BLOCKING_PRIORITY = 0          # >0 = participates in move-block pipeline
    IS_TIER_BASED_PASSIVE = False  # True = spartan_guard pattern
    MAX_TIER = 1                   # Set to 2 for tier-2 skills
    TIER_UNLOCK_LEVELS = {1: 1, 2: 10}
    GRANTS_IMMUNITY = []           # e.g. ['frozen_files']
    BLOCKED_BY_IMMUNITY = []

    # ── Required abstract methods (must implement all three) ──────────────
    def validate(self, **kwargs) -> dict:
        """Can the skill activate? Return {'valid': bool, 'reason': str}"""

    def apply(self, **kwargs) -> dict:
        """Execute effect. Return {'success': bool, 'new_fen': str, ...}"""

    def get_affected_squares(self, **kwargs) -> list:
        """Which squares does this skill touch?"""

    # ── Optional hooks (implement only what the skill needs) ─────────────
    def get_activation_options(self, **kwargs) -> dict:
        """For active skills with target selection. Returns valid targets."""

    def blocks_move(self, **kwargs) -> dict:
        """Return {'blocked': True, 'reason': str} to block a move."""

    def process_turn(self, skill_state: dict, request, **kwargs) -> dict:
        """Called every half-move while skill is active. Update counters,
        expire skill, apply per-turn effects. Return updated_state."""

    def build_ui_hints(self, skill_state: dict, **kwargs) -> dict:
        """Return structured hints the frontend reads from ui_hints payload.
        If this returns empty/None, the frontend shows nothing."""

    def on_piece_captured(self, **kwargs) -> dict:
        """Hook for kill-based charge accumulation."""
```

> [!IMPORTANT]
> **`process_turn` must return `updated_state`**.
> If `process_turn` returns `{}` or omits `updated_state`, the skill drops from
> `active_skills` on the next turn. Always include:
> ```python
> return {
>     'updated_state': skill_state,   # ← must include even if unchanged
>     'expired': False,
> }
> ```

> [!IMPORTANT]
> **`build_ui_hints` is why the frontend shows nothing**.
> The most common bug: `build_ui_hints` returns `{}` or `None` because the
> skill state key it reads doesn't exist yet. Always guard with `skill_state.get(...)`.

---

## 4. Tier-2 / Passive Pattern (Spartan Guard Reference)

Spartan Guard is the canonical example for any passive or tier-2 skill. Study this pattern
before implementing any passive.

### How Tier-2 State Reaches Python

```
Laravel buildSkillTiersForPython()
    ↓
request.skill_tiers = {
    "spartan_guard_w": {"tier": 2, ...},
    "spartan_guard_b": {"tier": 1, ...}
}
    ↓
manager.py _resolve_skill_tier()
    ↓
skill_class.apply() / process_turn() receives tier
```

### Key Locations in spartan_guard.py

```python
# How the skill reads its tier
tier = kwargs.get('tier', 1)   # passed by manager from skill_tiers

# How discipline counter is stored in active_skills state
skill_state['discipline_counter'] = counter

# How process_turn expires the skill
if half_moves_remaining <= 0:
    return {'expired': True, 'updated_state': skill_state}
```

### Checking If Tier-2 Works

```bash
# Run the checker — it validates tier config in wild_skills.php
cd api/python-chess-engine
.venv/bin/python3 scripts/check_skill_registration.py --skill spartan_guard
```

Look for `tier_2 block found` in the output. If missing, add it to `wild_skills.php`.

---

## 5. The Six Registration Layers

A skill MUST be wired in all six layers. Missing any one layer causes silent failure.

| # | Layer | File | What to Check |
|---|-------|------|---------------|
| 1 | Python class | `app/skills/{skill_id}.py` | Extends `BaseSkill`, `SKILL_ID` matches filename |
| 2 | Laravel config | `config/wild_skills.php` | Entry under `skills`, `skill_charge_mapping` present |
| 3 | Laravel service | `SkillEffectService.php` | Charge type mapping, tier handling if needed |
| 4 | Frontend config | `src/config/abilities.ts` | Entry in `WILD_SKILLS` or `CHARACTER_WILD_SKILLS` |
| 5 | Frontend component | `src/components/skills/registry.ts` | `SKILL_COMPONENT_REGISTRY` (OK to skip if no custom UI) |
| 6 | Python registry | auto-discovery | `SkillRegistry.get_skill_ids()` returns the skill_id |

**Verify all six at once:**
```bash
cd api/python-chess-engine
.venv/bin/python3 scripts/check_skill_registration.py --skill {skill_id}
```

```bash
# Frontend layers
cd chess
bash scripts/check_skill_frontend.sh {skill_id}
```

---

## 6. Debugging Protocol — Use This Exact Order

> [!CAUTION]
> Do NOT guess at a fix based on logs alone. The logs show output, not process.
> Follow this protocol. Stop at the step that reveals the root cause.

### Step 1 — Run the Registration Checker (30 seconds)

```bash
cd api/python-chess-engine
.venv/bin/python3 scripts/check_skill_registration.py --skill {skill_id}
```

Fixes 80% of issues. Common findings:
- ❌ `SKILL_ID mismatch` → rename the class constant or the file
- ❌ `Not in wild_skills.php` → add the config entry
- ❌ `Not in SKILL_COMPONENT_REGISTRY` → add to `registry.ts` or verify it's intentionally passive-only
- ❌ `Not in abilities.ts` → add to `WILD_SKILLS`

### Step 2 — Read the Laravel Structured Logs

When `APP_ENV=local`, every `process-turn` call emits two structured log lines to stderr:

```
[SKILL_DEBUG] process-turn → Python {
    "game_id": 288,
    "move": "e2→e3",
    "active_skill_keys": ["spartan_guard_w", "spartan_guard_b"],
    "skill_tiers": {"spartan_guard_w": {"tier": 2}},
    "active_skills": { ... full state ... }
}

[SKILL_DEBUG] process-turn ← Python {
    "game_id": 288,
    "fen_changed": false,
    "events_count": 0,
    "updated_skill_keys": ["spartan_guard_w"],
    "ui_hint_keys": ["piece_indicators"],
    "skill_inner_states": {"spartan_guard_w": {"discipline_state": "armed"}},
    "ui_hints_empty_reason": null
}
```

**Read `ui_hints_empty_reason`** — it tells you exactly why the frontend sees nothing:
- `"ui_hints=null (Python returned nothing)"` → `build_ui_hints` threw an exception or returned None
- `"no active skills in response"` → `process_turn` didn't return `updated_state`
- `"ui_hints present but all keys empty"` → `build_ui_hints` returned keys but all values empty

### Step 3 — Use the In-App SkillDebugScreen

1. Open Skill Test Lab in the app
2. Tap **🔬** (top-right corner)
3. Enter the game ID (from server logs or URL)
4. Make a move in the game
5. Tap **Refresh** (or enable auto-refresh)
6. Read the per-call breakdown:
   - `request.active_skill_keys` — what PHP sent to Python
   - `response.skill_inner_states` — what Python returned as state
   - `response.events` — what events Python emitted
   - `response.fen_changed` — did Python mutate the board

### Step 4 — Query the Python Debug Endpoint Directly

```bash
curl -X POST http://localhost:8095/skill/debug-state \
  -H 'Content-Type: application/json' \
  -d '{"game_id": "288"}'
```

Returns the last 20 `process_turn` calls for that game, including full inner states.

### Step 5 — Add a Targeted Python Log

If the above steps don't reveal the cause, add a temporary log inside the specific
`process_turn` or `build_ui_hints` method:

```python
import logging
logger = logging.getLogger("chess-engine")

def process_turn(self, skill_state, request, **kwargs):
    logger.debug(f"[{self.SKILL_ID}] process_turn called | state={skill_state} | tier={kwargs.get('tier')}")
    # ... your logic ...
```

Then tail the Python engine logs while making a move in a dev game.

---

## 7. Common Failure Signatures

### "ui_hints is empty / frontend shows nothing"

**Cause A**: `build_ui_hints` reads a state key that doesn't exist yet.
```python
# WRONG — KeyError silently caught, returns {}
counter = skill_state['discipline_counter']

# RIGHT
counter = skill_state.get('discipline_counter', 0)
```

**Cause B**: `process_turn` didn't return `updated_state`, skill expired on turn 1.
```python
# WRONG — skill disappears after first turn
return {'half_moves_remaining': remaining}

# RIGHT
return {
    'updated_state': {**skill_state, 'half_moves_remaining': remaining},
    'expired': remaining <= 0,
}
```

**Cause C**: Skill not in `active_skills` at all — PHP sent an empty dict.
→ Check `[SKILL_DEBUG] process-turn → Python` log for `active_skill_keys`.

### "Tier-2 passive not firing"

**Cause A**: `wild_skills.php` missing `tier_2` block.
→ Run checker, look for `⚠️ tier_2 block not found`.

**Cause B**: `buildSkillTiersForPython()` in Laravel not including this skill.
→ Search `SkillEffectService.php` for `buildSkillTiersForPython`. Verify the skill_id is handled.

**Cause C**: Python reads tier from wrong key.
→ In `process_turn`, log `kwargs.get('tier', 'NOT FOUND')`. If it's 1 when expecting 2,
  the tier is not making it through from `request.skill_tiers`.

**Cause D**: `IS_TIER_BASED_PASSIVE = True` not set on the class.
→ Without this, `manager._get_tier_based_passives()` skips the skill.

### "Skill fires for me but not for opponent"

The skill's `build_ui_hints` output is always from the skill owner's perspective.
The `socket_color` in the socket payload determines which player the hints target.

Check `skillEventDispatcher.ts` — the opponent sees the skill via the `skill_ui_hints`
socket key, not via local state.

### "blocks_move doesn't block"

**Cause A**: `BLOCKING_PRIORITY = 0` (default). Skill is not in the blocking pipeline.
→ Set `BLOCKING_PRIORITY = 10` (or appropriate value).

**Cause B**: Color normalization. The manager passes `player_color` as a string or bool.
→ Always normalize:
```python
player_color = kwargs.get('player_color')
if isinstance(player_color, str):
    player_color = player_color.lower() in ['w', 'white']
elif player_color is not None:
    player_color = bool(player_color)
```

### "Skill activates but FEN doesn't change"

`apply()` must return `new_fen` as a string if the board was mutated.
```python
# WRONG
return {'success': True}

# RIGHT
board.remove_piece_at(target_square)
return {
    'success': True,
    'new_fen': board.fen(),
    'fen_changed': True,
}
```

### "Knight escape (Spartan Guard) second jump fails"

The escape uses a separate endpoint (`/skill/validate-escape`) and a custom move path.
The standard chess.js on the frontend correctly throws `Invalid move` for 2x knight jumps —
this is expected and handled. The authoritative Python FEN overrides the local board.

---

## 8. Implementation Checklist — Adding a New Skill

### Pre-Implementation: Define the Contract First

Write these down before touching any file. Ambiguity here causes all the bugs.

```
skill_id:              _________________________
character_id:          _________________________
skill type:            [ ] active  [ ] passive  [ ] triggered
charge type:           [ ] INSTANT  [ ] KILL_BASED  [ ] MOVE_BASED
selection type:        [ ] piece  [ ] zone  [ ] file  [ ] null
tier-2 behavior:       [ ] yes  [ ] no
blocks moves:          [ ] yes  [ ] no
processes per turn:    [ ] yes  [ ] no
gate AI can use it:    [ ] yes  [ ] no
custom UI component:   [ ] yes  [ ] no
```

### Python Layer

- [ ] Copy the appropriate template (`passive_template.py`, `active_template.py`, etc.)
- [ ] Rename file to `{skill_id}.py`
- [ ] Set `SKILL_ID`, `SKILL_NAME`, `CATEGORIES`, `CHARGE_TYPE`
- [ ] Implement `validate()`, `apply()`, `get_affected_squares()`
- [ ] Implement optional hooks only if the skill needs them
- [ ] Test with `.venv/bin/python3 scripts/check_skill_registration.py --skill {skill_id}`

### Laravel Layer

- [ ] Add skill entry to `config/wild_skills.php` (name, description, charge_mapping, tiers)
- [ ] Add tier_2 block if applicable
- [ ] Add `character_id → skill_id` to `character_skills.json`
- [ ] Check `SkillEffectService.php::normalizeActiveSkillsForPython()` — new state fields?
- [ ] Check `SkillEffectService.php::buildSkillTiersForPython()` — tier handled?

### Frontend Layer

- [ ] Add to `WILD_SKILLS` in `src/config/abilities.ts`
- [ ] Add to `CHARACTER_WILD_SKILLS` in `src/config/abilities.ts`
- [ ] Add to `SKILL_IDS` in `src/config/skillDefinitions.ts`
- [ ] Add selection type and backend params in `skillDefinitions.ts`
- [ ] Add to `SKILL_COMPONENT_REGISTRY` in `registry.ts` (or confirm passive = no entry needed)
- [ ] Add to `skillEventDispatcher.ts` if opponent needs visual feedback
- [ ] Add cut-in config in `skillActivationConfig.ts` if character has custom activation

### Gate AI (only if AI can use it)

- [ ] Add imports and enum in `gate_ai_engine.py`
- [ ] Add per-skill state fields and heuristics
- [ ] Update `GateAIService.php` if AI state needs translation

### Verification

- [ ] `cd api/python-chess-engine && .venv/bin/python3 scripts/check_skill_registration.py --skill {skill_id}`
- [ ] `cd chess && bash scripts/check_skill_frontend.sh {skill_id}`
- [ ] `cd chess && npx tsc --noEmit`
- [ ] `cd api && php artisan test --compact tests/Feature/`
- [ ] Start a dev game in Skill Test Lab, make moves, verify in 🔬 SkillDebugScreen

---

## 9. Implementation Checklist — Debugging an Existing Skill

- [ ] Run registration checker: `check_skill_registration.py --skill {skill_id}`
- [ ] Read `[SKILL_DEBUG]` Laravel logs: what did PHP send, what did Python return?
- [ ] Check `ui_hints_empty_reason` in the log
- [ ] Open 🔬 SkillDebugScreen, fetch the game, read `skill_inner_states`
- [ ] Confirm `process_turn` returns `updated_state` on every code path
- [ ] Confirm `build_ui_hints` uses `.get()` not direct key access
- [ ] Confirm color normalization in `blocks_move` if blocking doesn't work
- [ ] Confirm `BLOCKING_PRIORITY > 0` if this skill should block moves
- [ ] Confirm `IS_TIER_BASED_PASSIVE = True` if this is a tier-based passive
- [ ] Confirm `tier_2` block exists in `wild_skills.php` for tier-2 behavior

---

## 10. Engineering Rules

> [!CAUTION]
> **Never implement skill rules in the frontend or Laravel.**
> All move legality, state transitions, and skill effects are authoritative in Python only.
> A rule written in TypeScript or PHP creates two sources of truth and will diverge.

> [!CAUTION]
> **Color normalization is mandatory in every skill hook.**
> Colors arrive as `'w'`, `'b'`, `'white'`, `'black'`, `True`, or `False` depending on
> the call site. Normalize at the top of every method that receives a color parameter.
> Not doing this is the second most common bug.

> [!IMPORTANT]
> **`active_skills` dict key format is `{skill_id}_{color}`.**
> Example: `"spartan_guard_w"`, `"golden_gambit_b"`. The color suffix is always a single
> character (`w` or `b`). Forgetting this means the skill never finds its own state.

> [!IMPORTANT]
> **`process_turn` is called every half-move for every active skill.**
> It must be fast. Do not make HTTP calls, query databases, or run expensive loops inside it.

> [!TIP]
> **Search by exact skill_id before editing.**
> Run `grep -r "skill_id_here" .` across the full workspace before making changes.
> There are always more references than you expect, including label maps, overlays, and
> Gate AI enum lists.

> [!TIP]
> **Coordinates are always lowercase.**
> Normalize all square names: `move_from.lower()`, `move_to.lower()`. Mixed case (e.g. `F3`
> vs `f3`) causes silent mismatches in blocking logic.

---

## 11. Verification Commands

```bash
# ── Python registration (run first, always) ──────────────────────────────
cd api/python-chess-engine
.venv/bin/python3 scripts/check_skill_registration.py --skill {skill_id}

# ── Frontend registration ─────────────────────────────────────────────────
cd chess
bash scripts/check_skill_frontend.sh {skill_id}

# ── TypeScript type check ─────────────────────────────────────────────────
cd chess
npx tsc --noEmit

# ── Laravel tests ─────────────────────────────────────────────────────────
cd api
php artisan test --compact

# ── Python unit tests ─────────────────────────────────────────────────────
cd api/python-chess-engine
.venv/bin/python3 -m pytest tests/ -v

# ── Query Python SkillTracer live ─────────────────────────────────────────
curl -X POST http://localhost:8095/skill/debug-state \
  -H 'Content-Type: application/json' \
  -d '{"game_id": "GAME_ID_HERE"}'

# ── Verify Python imports cleanly ─────────────────────────────────────────
cd api/python-chess-engine
.venv/bin/python3 -c "
from app.skills.manager import SkillTracer
from app.skills.registry import SkillRegistry
SkillRegistry._discover_skills()
print('Skills:', sorted(SkillRegistry.get_skill_ids()))
"

# ── Check Laravel logs for SKILL_DEBUG lines ──────────────────────────────
# Tail server stderr while making a move:
# xserver already tails this — just make a move and look for [SKILL_DEBUG] lines
```

---

## 12. All Skill IDs + Characters Reference

| skill_id | Character | Tier-2 | Type |
|----------|-----------|--------|------|
| `spartan_guard` | Chess Knight (Leonidas) | ✅ | Passive + Active |
| `golden_gambit` | Valeria | ✅ | Active (zone) |
| `void_barrier` | Shirokage Ren | ✅ | Active (zone) |
| `void_exile` | Shirokage Ren (T2) | — | Triggered |
| `frozen_files` | Lysandra Frostborn | ✅ | Active (file) |
| `trash_talk` | Neon Rex | ✅ | Passive + Active |
| `blood_moon_empire` | Enryuu Akatsura | ✅ | Triggered (per-turn) |
| `omen_of_the_black_court` | Seravelle Noctryn | ✅ | Triggered |
| `surge_of_phantoms` | — | — | Active (placement) |
| `imperial_decree` | Xyrath | — | Active |

---

## 13. What To Produce When Using This Skill

When an agent uses this guide, it should produce:

**For debugging:**
1. Run the registration checker and report its output verbatim
2. Read the structured PHP logs and state the exact `ui_hints_empty_reason`
3. State the exact root cause from the failure signatures in Section 7
4. Make the minimal fix — one change, in the correct layer
5. Re-run the checker and confirm it passes

**For implementing a new skill:**
1. Define the contract (Section 8, pre-implementation block)
2. Copy the appropriate template
3. Work through the checklist layer by layer (Python → Laravel → Frontend)
4. Run all verification commands
5. Confirm in the 🔬 SkillDebugScreen after making moves in a dev game
