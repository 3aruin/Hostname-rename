# CLAUDE.md

Guidance for AI assistants working in this repository. Read this before making
any change; it encodes constraints that are not obvious from the code and that
CI will fail on if broken.

---

## What this project is

Hostname-Rename renames Windows devices to a standard naming convention. It is
delivered as a single `irm | iex` one-liner from GitHub: `launcher.ps1` is
fetched over HTTPS, self-elevates through UAC, downloads six module files,
verifies each against a SHA-256 manifest, dot-sources them, and calls
`Rename-DeviceSmart`.

There is no build step, no package manager, and no third-party dependency
(ADR-005). The unit of deployment is a pinned commit SHA.

**Two naming modes:**

| Mode | Format | Example |
|---|---|---|
| Gateway (default) | `{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}` | `AC01R-WSDT-A3F9` |
| User | `{WH}{LOC}-{Name}` | `01R-JaneDoe` |

Windows enforces a 15-character NetBIOS limit. `ORG` must be exactly two
characters — `AA00A-AABB-0000` is exactly 15. If the full Gateway name
overflows, the department segment is dropped automatically.

---

## Repository layout

```
launcher.ps1        Entry point: fetch, verify hashes, elevate, dot-source, hand off
logging.ps1         Initialize-Log / Write-Log / Remove-OldLogFile  (loaded first)
network.ps1         $GATEWAY_MAP, $FALLBACK_CONTEXT, Get-DefaultGateway, Get-NetworkContext
device.ps1          $VALID_DEPARTMENTS, $DEVICE_TYPES, Get-Department, Get-DeviceType,
                    Resolve-DeviceType, Get-SerialLast4, ConvertTo-SerialLast4,
                    Get-UserName, ConvertTo-CleanUserName
naming.ps1          Select-NamingMode, New-DeviceName, New-UserDeviceName
gui.ps1             Show-RenameGui, Resolve-GatewayPreview, Update-RenameGuiPreview,
                    Get-RenameGuiXaml, $GUI_UNAVAILABLE          (only used with -Gui)
rename.ps1          Rename-DeviceSmart — the orchestrator, owns ShouldProcess and logging
tests/              Pester v5 suites (core + GUI)
tools/Get-Hashes.ps1  Regenerates the $MANIFEST block for launcher.ps1
.github/workflows/ci.yml  lint / test / manifest / placeholder
```

**Load order is load-bearing** and is duplicated in three places that must stay
in sync: `$MODULES` in `launcher.ps1`, `$files` in `tools/Get-Hashes.ps1`, and
the diagram in `INDEX.md`.

```
logging.ps1 → network.ps1 → device.ps1 → naming.ps1 → gui.ps1 → rename.ps1
```

`logging.ps1` is first so the orchestrator can log the whole run. `gui.ps1` sits
after `naming.ps1` (its live preview calls the name builders) and before
`rename.ps1` (which calls `Show-RenameGui`).

---

## Architecture rules

### The integrity model (ADR-001, ADR-002)

`launcher.ps1` runs downloaded code **elevated**, so it must verify what it
downloads:

- `$COMMIT_SHA` pins the commit the modules are fetched from.
- `$MANIFEST` holds a SHA-256 per module, checked before dot-sourcing.
- An unpinned launcher (`$COMMIT_SHA` still `REPLACE_WITH_COMMIT_SHA`) **refuses
  to run** unless `-AllowUnverified` is passed (SEC-001, development only).
- A *pinned* launcher with any `REPLACE_WITH_HASH` entry left throws — a
  half-regenerated manifest would load some modules unverified (SEC-002).

Never weaken these guards. Never suggest pinning a deployment URL to `main` —
a branch ref can be force-pushed, which makes the hash check meaningless.

### Module contracts

- **`rename.ps1` owns all state change.** It holds the sole
  `$PSCmdlet.ShouldProcess` gate and the only `Rename-Computer` call. No other
  module renames anything.
- **`gui.ps1` is a presentation layer only.** It never calls `Rename-Computer`
  and never calls `Write-Log`. It returns a hashtable of inputs, `$null` for
  "operator cancelled", or the `$script:GUI_UNAVAILABLE` sentinel.
- **Pure decision functions are separated from I/O.** `Resolve-DeviceType` owns
  the type priority chain; `Get-DeviceType` only collects WMI values and passes
  them in. `Resolve-GatewayPreview` owns preview logic; `Update-RenameGuiPreview`
  only binds it to controls. This split is what makes the suite testable without
  a real device or WPF — preserve it when adding logic.

### The three never-block rules

1. **Logging never blocks a rename** (ADR-007). Init failure warns and disables
   logging; write failures use `-ErrorAction SilentlyContinue`. Retention
   housekeeping swallows its own errors.
2. **A GUI failure never blocks a rename** (ADR-008). Anything GUI-shaped probes
   its preconditions (`[Environment]::UserInteractive`, STA thread,
   `PresentationFramework` loads) and returns the sentinel rather than throwing.
3. **Never guess in automation.** The mirror of the above: under
   `-NonInteractive`, an unmapped gateway *throws* instead of falling back, and
   `-Gui -NonInteractive` throws immediately, before any other work. A silently
   wrong device name is worse than a failed rename (BUG-002).

---

## Hard constraints — CI enforces these

### ASCII-only, no BOM, in every `.ps1`

Use `--` instead of em dashes, `->` instead of arrows. No box-drawing, no fancy
quotes — including inside the XAML here-string in `gui.ps1`. A single non-ASCII
character forces a UTF-8 BOM, which Windows PowerShell 5.1 then mis-decodes, and
`PSUseBOMForUnicodeEncodedFile` flags it. Markdown docs may use Unicode freely.

### LF line endings on `.ps1` (BUG-017)

`.gitattributes` pins `*.ps1` to `eol=lf`. Three parties hash module bytes —
`tools/Get-Hashes.ps1` locally, the CI `manifest` job, and `launcher.ps1` at
runtime against what `raw.githubusercontent.com` serves. SHA-256 over text is
CRLF/LF sensitive, so all three must see identical bytes. `Get-Hashes.ps1` warns
on a BOM or any CR byte rather than emitting a hash that cannot match.

### The XAML is static (ADR-008)

`Get-RenameGuiXaml` returns a single-quoted here-string containing **zero `$`
characters**. Runtime data (profile names, hostnames, serials, WMI strings) goes
into control properties (`.Text`, `Items.Add`, `.Tag`) *after*
`XamlReader::Parse`. XAML is executable — a spliced string is an injection
vector. A Pester assertion greps the returned XAML for `$` and fails on any hit.

### Style

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"` are set
  in the launcher; all code must be clean under them. Wrap pipeline results in
  `@()` before touching `.Count`.
- `Write-Warning` for operator-visible issues, `Write-Verbose` for debug detail.
- Every interactive prompt needs a `-NonInteractive` bypass. A function that
  accepts `-NonInteractive` must never reach `Read-Host` under that flag.
- Interactive `Read-Host` loops need bounded retries (F-08.4) — redirected stdin
  returns `""` forever otherwise.
- No empty `catch` blocks (`PSAvoidUsingEmptyCatchBlock`); put a real statement
  in, or use `-ErrorAction SilentlyContinue` on the call.
- Analyzer suppressions are used deliberately and each carries a `Justification`
  string. Read the existing ones before adding a new suppression.

---

## Development workflow

### Run the checks locally

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
Invoke-Pester ./tests -Output Detailed

Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning
```

Both must be clean before a PR. The GUI suite's XAML smoke tests skip cleanly
where `PresentationFramework` is absent (Server Core, non-Windows); everything
else still runs.

Note this container is Linux — PowerShell, Pester and PSScriptAnalyzer may not
be installed. If you cannot run the suites, say so explicitly rather than
implying they passed; CI runs both on `windows-latest`.

### CI (`.github/workflows/ci.yml`)

| Job | What it does |
|---|---|
| `lint` | PSScriptAnalyzer, matrix over real PS 5.1 (`shell: powershell`) and 7.x (`shell: pwsh`) |
| `test` | Pester 5, same two-shell matrix |
| `manifest` | Recomputes module hashes from on-disk bytes and compares to `$MANIFEST` |
| `placeholder` | Fails if `REPLACE_WITH_COMMIT_SHA` is present (`continue-on-error` on `main` only, so the canonical template state stays green) |

The shell **is** the version selector (BUG-013a): a matrix axis no step
references does nothing. Keep `shell: ${{ matrix.shell }}` on every step that
needs a specific PowerShell edition.

### After changing any module file

The manifest must be regenerated or CI's `manifest` job fails:

```powershell
.\tools\Get-Hashes.ps1     # paste output over $MANIFEST in launcher.ps1
```

Commit the module change and the updated `$MANIFEST` **in the same commit**.

### Deployment (two commits, unavoidable)

1. Edit modules, run `Get-Hashes.ps1`, paste into `$MANIFEST`, commit + push →
   this SHA is the **module commit**.
2. Set `$COMMIT_SHA` to the module-commit SHA, commit + push → this SHA is the
   **launcher commit**, and it goes in the deployment URL.

A file cannot contain the SHA of the commit it is part of, so the launcher pins
the *previous* commit — the one already holding the modules and their hashes.

---

## Extending the tool

**New site gateway:** add to `$script:GATEWAY_MAP` in `network.ps1`. `ORG` must
be exactly 2 characters, `WH` a two-digit *string* (`"01"`, not `1`), `LOC` a
single letter. Example IPs are RFC 5737 ranges — replace before deploying.

**New department:** append the two-character code to `$script:VALID_DEPARTMENTS`
in `device.ps1`. The prompt and the GUI dropdown pick it up automatically.

**New device type:**
1. Append the code to `$script:DEVICE_TYPES` in `device.ps1`.
2. Add a branch to `Resolve-DeviceType` **before** the `DT` fallback, in the
   right priority position. The chain is order-sensitive: `SV` before the chassis
   tests so a server OS always wins; `TB` before `MD` so an ARM convertible keeps
   its form factor. Available values are `$Model`, `$ProductType`,
   `$Architecture`, `$ChassisTypes`.
3. If you need a class beyond the four `Get-DeviceType` collects, add the
   `Get-CimInstance` call there and pass the value through.
4. Add a Pester case to the `Resolve-DeviceType` block in the core test file.

`ET` (thin client) is manual-override-only by design — no reliable WMI signal.

---

## Traps that have already bitten this codebase

These are documented as BUG-NNN / SEC-NNN / F-NN in `DECISIONS.md` and
`REVIEW-FINDINGS.md`. Do not reintroduce them.

- **`Get-CimInstance` has no `-AsJob` parameter** on any PowerShell edition
  (BUG-015). "Parallel" CIM detection threw a binding error and every device
  silently detected as `DT` for three releases. Detection is sequential on
  purpose. `Start-Job` is still used in `launcher.ps1` for the HTTP fetches —
  that is fine, it is `Invoke-WebRequest`, not CIM.
- **Elevation relaunch quoting is per-path** (BUG-014). The `-File` path goes
  through the native command line where double quotes group arguments and single
  quotes are *literal*; the `iex` path is spliced into `-Command "..."` where
  single quotes are the safe wrapper. A double quote in a forwarded value is
  refused outright (SEC-003). `wt.exe` splits on `;`, so those are escaped as
  `\;` on both paths (F-08.5).
- **`iex (…) -Args` cannot forward parameters** (BUG-016). `Invoke-Expression`
  takes one `-Command` argument; trailing tokens are binding errors. Use
  `& ([scriptblock]::Create((irm 'url'))) -Params`.
- **`[Console]::KeyAvailable` throws when stdin is redirected** (BUG-018) —
  piped input, some remoting hosts, RMM agents. Caught, and treated as the
  documented Gateway default rather than a crash.
- **Default-gateway selection must be metric-aware** (BUG-019). `Get-NetRoute`
  sorted by `RouteMetric + InterfaceMetric`; the legacy adapter query is filtered
  to IPv4 because `$GATEWAY_MAP` is IPv4-keyed. Note the property is
  `InterfaceMetric` — `ifMetric` is a display column only, and `Sort-Object` on a
  nonexistent property silently does not sort.
- **`Invoke-WebRequest` has no default timeout** (BUG-020). Fetches use
  `-TimeoutSec 60` inside the job plus `Wait-Job -Timeout 90` outside it.
- **Manifest hex matching is case-insensitive** (F-08.2). A lowercase-only regex
  silently *skipped* verification of an uppercase-pasted hash.
- **UNC `-LogPath` / `-FolderPath` authenticate the elevated machine over SMB**
  (SEC-004). Both warn once, up front. Keep the warnings.
- **`-Username` is matched as a literal**, escaped via
  `[WildcardPattern]::Escape` (SEC-005) — an unescaped `*` would match unintended
  profiles.

---

## Documentation conventions

This repo carries an unusually heavy doc set, and it is expected to stay in sync.
When you change behaviour:

| File | Update it when |
|---|---|
| `CHANGELOG.md` | Always. Keep-a-Changelog format, semver headings. |
| `DECISIONS.md` | A design decision (ADR-NNN), a bug (BUG-NNN), a security finding (SEC-NNN), or an open question (OQ-NNN) is resolved. This is the "why" file — new numbers continue the existing sequences. |
| `README.md` | User-visible behaviour: parameters, name format, valid codes. |
| `CONTRIBUTING.md` | Workflow, customisation points, code style. |
| `INDEX.md` | Files added/removed, load order changed, current version. |
| `REVIEW-FINDINGS.md` | Output of a review pass (F-NN items); historical record. |

`DECISIONS.md` and `README.md` cross-reference each other by ADR/BUG number —
when citing a rationale in a code comment, use the identifier (`BUG-015`,
`ADR-008`) rather than restating the reasoning.

**Known drift as of this writing:** `INDEX.md` states "Current version v3.3.0"
and `CONTRIBUTING.md`'s "Shipped in" tables stop at v3.3, while `CHANGELOG.md`
has shipped `[3.8.0] — 2026-07-12` and `DECISIONS.md` records the v3.8 review
pass. Treat `CHANGELOG.md` + `DECISIONS.md` as authoritative on version state,
and fix the stale files if you touch them.

---

## Git and PR conventions

- Branch naming: `fix/<short-description>` or `feat/<short-description>`.
- Open an issue first for anything beyond a trivial fix.
- Push with `git push -u origin <branch>`; retry network failures with backoff.
- Do not open a pull request unless explicitly asked.
- PR descriptions reference the relevant issue or the `DECISIONS.md` identifier
  (OQ-NNN / ADR-NNN / BUG-NNN).
- CI must be green before merge.
- History is squashed/opaque upstream (most commits read "Add files via upload"),
  so `git log` is not a useful source of rationale — `DECISIONS.md` is.

---

## Model-specific notes for AI assistants

The current Claude generation — Opus 5 and the higher-capability Fable line —
behaves differently from earlier models in ways that matter in *this* repo
specifically. These are behavioural notes, not API instructions; nothing in this
project calls an LLM API.

### Opus 5

- **It verifies its own work without being told.** Do not add "double-check
  before responding" or "run a verification step" instructions, and do not build
  verification scaffolding into a workflow here — on this model that produces
  over-verification, not more correctness. The existing Pester + PSScriptAnalyzer
  gates are the verification layer; that is sufficient.
- **It writes long by default** — both conversational replies and files on disk.
  This repo's docs are already ~150 KB; an unprompted "improvement" pass will
  balloon them. Be selective about what you add. Lowering effort does *not*
  reliably shorten output; explicit brevity instructions do.
- **It can expand task scope.** That is expensive here: any change to a module
  file obligates a manifest regeneration and a two-commit deployment dance, and
  a doc update across up to five files. Deliver the scope asked for, state
  assumptions, and stop.
- **It delegates to subagents readily.** This is a nine-file repo with no build
  system — a subagent almost never pays for itself. Read the files directly.
- **It narrates self-corrections at length.** Correct plainly and move on; only
  flag an earlier statement when the error changes what the user should do.
- **Thinking is on by default** and its raw chain of thought is never returned.
  If thinking is explicitly disabled, two failure modes appear that are easy to
  misread as tool bugs: a tool call can be emitted as plain visible text (the
  call never runs, and the turn still reports success), and `<thinking>` tags can
  leak into the response. Prefer leaving thinking on at lower effort.
- **It follows severity filters literally.** If you ask it to review this code
  and say "only report high-severity issues", it will honour that and measured
  recall drops even though it found the bugs. Ask for every finding with a
  confidence and severity, then filter in a second pass.

### Fable

- **Thinking is always on and not configurable**; the raw chain of thought is
  never returned. Only summaries are available.
- **It runs long.** Single turns on hard tasks can take many minutes. Plan for
  asynchronous check-ins rather than assuming a fast round trip.
- **Safety classifiers can decline a request outright**, returning a refusal
  rather than an error. This repo is security-adjacent in exactly the ways that
  can trip a false positive — UAC self-elevation, command-line injection
  hardening, hash-verification bypass switches, NTLM/SMB coercion warnings, XAML
  injection. If a benign task here is refused, that is a classifier false
  positive, not a judgement about the request; a fallback model handles it.
- **Over-prescriptive prompting reduces its output quality.** Prompts and skills
  written step-by-step for older models should be de-prescribed: state the goal
  and the constraints (the invariants in this file), not the sequence of steps.
- **State boundaries explicitly.** It will otherwise take adjacent, unrequested
  actions. In this repo that is a real hazard: creating backup branches, pushing
  to a branch other than the designated one, or opening a PR unprompted. All
  three are prohibited here.
- **Give it a place to write notes.** It performs measurably better with a
  scratch memory surface across a long session; `DECISIONS.md` is the durable
  equivalent for anything that should outlive the session.

### Applies to both

- Both models reach for tools less eagerly than older ones when a tool's
  description only says *what* it does. Descriptions that state *when* to call it
  get better triggering.
- Both are more literal about instructions. The invariants above ("ASCII-only",
  "no `$` in the XAML", "regenerate the manifest") are meant to apply to *every*
  edit, not just the first one in a session.
- Neither model needs the aggressive `CRITICAL: YOU MUST` phrasing that older
  models required. It causes overtriggering; plain declarative rules work better.
