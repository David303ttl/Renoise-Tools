# Repository development instructions

## Shell

- Use PowerShell 7 (`pwsh`) exclusively for repository scripts and shell work.
  Do not use Windows PowerShell (`powershell.exe`) or maintain 5.1 compatibility.

## Commit messages

- Follow [Conventional Commits 1.0.0](docs/COMMIT_MESSAGES.md) for new commits.
- Use `type(scope): description`, with a lowercase imperative description and
  no trailing period. Scope is optional; use a relevant tool or area when useful.
- Choose a type that describes the change: `feat`, `fix`, `docs`, `refactor`,
  `perf`, `test`, `build`, `ci`, `chore`, `style`, or `revert`.
- Mark breaking changes with `!` after the type/scope, and describe the change
  in a `BREAKING CHANGE:` footer when context is useful.
- Keep commits focused. Do not infer or change tool versions from commit types;
  each Renoise tool's version remains managed in its manifest.
- This is documented guidance only: do not add Git hooks, commit-message
  workflows, or other automatic enforcement for the commit format.

## Tool boundaries

- Each root `.xrnx` directory is independently installable. Keep `main.lua`,
  `manifest.xml`, and all runtime dependencies inside that tool's directory.
- ARP and ACID target Renoise 3.5 / scripting API 6.2, using Lua 5.1-compatible
  syntax. Do not raise manifest API or tool versions as incidental cleanup.
- DigitaktSampleChain is frozen unless the user explicitly requests work on it.
  Its existing manifest targets API 6.1; preserve that compatibility.
- Keep modules private to each tool. ACID uses qualified module names such as
  `model.compiler` and `writers.phrase_writer`.

## Code naming, comments and documentation

- Name code files, modules, symbols, tests and fixture formats by behavior or
  responsibility. Do not embed roadmap, blueprint, milestone, phase or work-step
  labels such as `M1` or `M2` in names, comments, generated code, diagnostics or
  UI text. Keep planning labels and implementation history in documentation.
- Keep comments concise and technical: describe behavior, invariants, constraints
  or the reason for a non-obvious decision. Do not add task narratives, progress
  reports, future-work prose or version-history commentary to code.
- Preserve meaningful domain terms such as sequencer steps and signal phase.
  Preserve manifest versions, persisted schema identifiers and compatibility
  markers; do not rename them as cosmetic cleanup.
- Keep documentation paths portable. Use repository-relative paths, pinned
  upstream links or sanitized placeholders for external checkouts. Never commit
  machine-specific absolute paths, usernames or local workspace locations.

## Renoise API references

- Run `./scripts/setup_sdk.ps1` to obtain the pinned API 6.2 starter pack.
- Before adding or changing Renoise API calls, inspect the relevant definitions
  under `sdk/renoise-api-6.2/definitions/` and the accompanying offline docs under
  `sdk/renoise-api-6.2/docs/`. Check signatures, indexing, access restrictions,
  observable lifetimes, and API availability rather than guessing from memory.
- If the SDK cannot be downloaded, consult the official versioned sources at
  <https://github.com/renoise/xrnx/tree/API-6.2> and explain any unresolved API
  uncertainty. The official online guide may describe a newer API.
- Definitions and examples are development references, not runtime libraries or
  substitutes for running Renoise. Never `require` them from a tool or copy the
  SDK into a tool bundle.
- `.luarc.json` configures the shared API library. Tool module names can overlap;
  do not add every tool root to one shared runtime module search path.

## Verification and releases

- Run `./scripts/run_tests.ps1` after Lua changes; `-Tool ARP` or `-Tool ACID`
  selects one suite. Every spec runs in a separate process to isolate mocks and
  module caches. Direct specs run from the repository root.
- Keep deterministic model behavior testable without Renoise. Use meaningful
  mocks for API integration, but do not claim those validate actual playback.
- Changes affecting notes, phrases, GUI, notifications, undo, or persistence
  require appropriate manual checks in Renoise using the guides in `tests/`.
  Report which checks were actually performed and which remain unverified.
- Run `./scripts/package.ps1` after changing runtime layout or package inputs.
  Packages must contain `manifest.xml` and `main.lua` at archive root, preserve
  module directories, and exclude the SDK and development files.
- Keep downloaded SDK files, build output, and temporary artifacts untracked.
  Release tools independently from their manifests, with tags such as `arp/v0.7`.
