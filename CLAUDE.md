# PizzaScript

Single-file Cherax (GTA V mod menu) Lua tool. `src/PizzaScript.lua` is the
whole project — new features go in as new sections of that one file, not
new files, unless told otherwise. (PizzaGames, an earlier 4-minigame
framework, was retired; it's gone from the working tree, still in git
history if ever needed.)

## Non-negotiable rules

- **Never invent native hashes, function names, or signatures.** If a
  capability isn't confirmed against a real source, say so and degrade to
  "no disponible" — don't guess. Wrong native args can crash the whole
  game, not just throw a Lua error.
- **Namespaces are NOT what community docs say.** This build's real API
  (`Stats`, `Players`, `GTA`, no `STATS`/`PED`/`PLAYER`/`NETWORK`) was
  confirmed by enumerating `_G` at runtime, not by trusting docs.cherax.vip
  or similar. If unsure what exists, regenerate the diagnostic: reload the
  script, it writes `Documents\Cherax\Lua\PizzaScript_Diag.txt` on every
  boot (enumerates `_G` via `pairs()`, never invokes anything).
- **Natives only after the script thread is armed.** The script body runs
  in a different thread when Cherax loads it; touching natives there
  closes GTA silently. Gate everything behind `Script.RegisterLooped`'s
  callback with a warmup delay (see `armed` in PizzaScript.lua).
- **Every network wait needs two independent brakes** (time limit AND
  iteration cap), never just one — a stuck brake hangs the game loop
  forever.
- **Never overwrite a file (including self-update) without verifying the
  new content compiles with `load()` first.** Keep a backup of what was
  replaced.
- `ClickGUI.RenderFeature` takes the feature **hash** (a number from
  `Utils.Joaat`), not the `Feature` object `FeatureMgr.AddFeature` returns.
  Passing the object kills the tab's coroutine (already bit us once).

## Verification before calling something done

- `luac5.4 -p src/PizzaScript.lua` (or the `sim/` test suite, `lua
  sim/run_tests.lua`) checks syntax and the self-update logic — but NOT
  whether native calls actually return real data. That only the user can
  confirm, in-game.
- Keep `Documents\Cherax\Lua\PizzaScript.lua` in sync with
  `src/PizzaScript.lua` after every change — that's the copy the user
  actually tests.
- The user tests in-game and reports back via `Cherax.log` excerpts or
  screenshots. Prefer having the script write diagnostics to a file under
  `Documents\Cherax\Lua\` (read directly) over asking the user to paste log
  sections.

## Git / releases

- Local clone: `C:\Users\yiffs\Documents\PizzaGames-repo` (folder name is
  stale, ignore it). Remote: `https://github.com/TuShaggy/PizzaScript`.
- `git push` needs the user's own interactive terminal the first time each
  session for GCM auth (silent hang in non-interactive Bash) — ask them to
  run it in their own Git Bash window if a push stalls.
- Version scheme: alpha style, e.g. `0.0.1-alpha` (`PS_VERSION` in the
  script and `version.json` at repo root, `{version, notas}` only).
