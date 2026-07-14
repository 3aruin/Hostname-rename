# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Nothing yet.

---

## [3.8.0] — 2026-07-12

### Fixed — v3.8 review pass, cleanup batch (2026-07-11, REVIEW-FINDINGS.md F-04…F-08)

- **F-04 / BUG-013(a)** — the CI lint matrix's "5.1" leg never actually ran
  Windows PowerShell (its `ps-version` axis was referenced by no step; both legs
  ran `pwsh`). The lint **and** test jobs now use a `matrix.include` that pairs
  each `ps-version` with its real `shell` (`powershell` / `pwsh`), so 5.1 is
  genuinely linted *and* tested. The 5.1 Pester leg needs `-SkipPublisherCheck`
  (5.1 ships Pester 3.4 under a different signing certificate); artifact names
  are now unique per leg (upload-artifact v4 rejects duplicates). Suite verified
  green under both editions locally: 95/95 each.
- **BUG-018 (F-05)** — `Select-NamingMode` crashed (`InvalidOperationException`
  from `[Console]::KeyAvailable`) when stdin is not a real console — piped
  input, some remoting hosts, RMM agents. It now announces the redirected input
  and takes the documented Gateway default, same as the timeout. Regression test
  drives a real child PowerShell with piped stdin.
- **BUG-019 (F-06)** — `Get-DefaultGateway` returned the first enumerated
  adapter's gateway (VPN/multi-NIC roulette) and could return an IPv6 literal
  that can never match the IPv4-keyed `GATEWAY_MAP`. Now returns the next-hop of
  the lowest-effective-metric IPv4 default route via `Get-NetRoute`
  (`RouteMetric + InterfaceMetric`, the same sum Windows uses — verified against
  `Find-NetRoute` on a dual-route machine), with the legacy query as an
  IPv4-filtered fallback.
- **BUG-020 (F-07)** — module fetches had no timeout anywhere (`iwr` defaults to
  infinite; `Receive-Job -Wait` waits forever), so a stalled connection hung
  unattended MDM runs indefinitely. Transfers are now bounded at 60 s in-job and
  90 s at collection, feeding the existing "Failed to fetch" error path.
- **BUG-021 (F-08, minor batch)** — UAC decline now exits with a clear message
  instead of a raw exception; the CI manifest regex accepts uppercase hex and
  **fails** (not warns) when a pinned SHA has zero parsable hashes (closes
  BUG-013(b)); `New-UserDeviceName` throws a clean error instead of
  `ArgumentOutOfRange` when WH+LOC leave no room; `Get-Department` /
  `Get-UserName` prompt loops bail out after 10 attempts instead of spinning
  forever on exhausted stdin; both `wt.exe` relaunch paths escape `;` as `\;`
  (wt's pane separator); and the GUI-fallback path reuses the pre-GUI device
  type and serial instead of re-querying WMI (`Get-DeviceType -Detected`).
- **Tests: 88 → 95.** New coverage: `-Detected` reuse and invalid-`-Detected`
  rejection, bounded prompt loops, redirected-stdin naming-mode default,
  IPv4-only gateway contract, and the `New-UserDeviceName` overflow guard; the
  GUI contract test now pins single-fetch fallback behaviour.

### Fixed — v3.8 review pass (2026-07-11, REVIEW-FINDINGS.md F-01…F-03)

- **BUG-015 (F-01, Critical)** — `Get-DeviceType`'s "parallel CIM queries" called
  `Get-CimInstance -AsJob`, a parameter that does not exist on any PowerShell
  edition. The binding error was swallowed by the blanket `catch`, so **every
  device silently detected as `DT`** in every real run since the code shipped.
  Replaced with four sequential `Get-CimInstance` calls; the fallback warning
  now includes the underlying exception message. Regression guards added: an
  AST check that every `Get-CimInstance` parameter in `device.ps1` is real,
  and a no-mock execution of `Get-DeviceType -NonInteractive` asserting the
  catch path is not taken.
- **BUG-016 (F-02, High)** — the iex-path elevation relaunch spliced forwarded
  parameters after `iex (irm 'url')`, where `Invoke-Expression`'s single
  `-Command` parameter makes every appended token a binding error — the
  parameterized non-admin one-liner could never work. Now builds
  `& ([scriptblock]::Create((irm 'url'))) <args>`, the form the launcher's own
  header documents. Regression guards: static shape assertion plus a real
  child-process `-Command` round-trip binding a spaced string, a switch, and
  an `[int]`.
- **BUG-017 (F-03, High)** — the hash-manifest pipeline was line-ending
  sensitive while the tree itself had mixed EOLs (three modules CRLF, four LF)
  and no `.gitattributes`, so a locally regenerated `$MANIFEST` could fail the
  runtime hash check on every device (fleet-wide fail-closed outage). Added
  `.gitattributes` (`*.ps1 text eol=lf`), normalized all modules to LF, and
  made `tools/Get-Hashes.ps1` and the CI manifest job hash raw on-disk bytes
  (`[IO.File]::ReadAllBytes`) — byte-identical with each other and with what
  `raw.githubusercontent.com` serves. `Get-Hashes.ps1` now warns if a module
  has a BOM or CRLF instead of emitting a hash that cannot match at runtime.

---

## [3.3.0] — 2026-07-11

Maintenance release. Ships the three v3.3 ideas queued in [3.2.0]'s Unreleased
section — configurable prompt timeout (OQ-004), log retention (ADR-009), and
chassis-based `LT` detection — plus one bug fix (BUG-014) found while wiring
the new parameter through the elevation relaunch. No behaviour changes for
existing invocations: every new parameter defaults to the previous behaviour,
and `-NonInteractive` deployments are untouched.

### Added

- **`-PromptTimeoutSeconds` (OQ-004).** The naming-mode prompt's timeout is now a
  parameter (`[int]`, `ValidateRange(1, 300)`), forwarded `launcher.ps1` →
  `Rename-DeviceSmart` → `Select-NamingMode`. Default stays 8 seconds, so
  omitting it is byte-for-byte the old behaviour. Console-only by design: the
  GUI window has no timed prompt, and `-NonInteractive` still skips the prompt
  entirely. Resolves OQ-004 (previously "fork and adjust").

- **Log retention (ADR-009).** `Initialize-Log` now prunes this tool's own run
  logs (`Hostname-Rename_*.log`) older than `$script:LOG_RETENTION_DAYS`
  (30 days) via the new `Remove-OldLogFile` helper — **only** in the default
  `%TEMP%\Hostname-Rename` directory. An explicit `-LogPath` (e.g. a shared UNC
  log share holding other machines' logs) is never pruned; retention there is
  the share owner's policy. Same never-block rule as all logging (ADR-007): any
  retention failure degrades to "old logs stay on disk". Deletion is gated by
  `ShouldProcess`, so a `-WhatIf` run prunes nothing.

- **Tests: 70 → 84.** New chassis-`LT` and priority cases, the
  `-PromptTimeoutSeconds` contract (accepted / range-validated / default-8
  pinned via AST / forwarded by `Rename-DeviceSmart`), and a `Remove-OldLogFile`
  retention block (expired removed, fresh kept, non-matching files never
  touched, `-WhatIf` removes nothing, missing directory never throws).

### Changed

- **`LT` detection is now chassis-first.** `Resolve-DeviceType` treats
  `Win32_SystemEnclosure.ChassisTypes` 9 (Laptop) / 10 (Notebook) as the
  authoritative laptop signal; the old `Model -match "Laptop"` heuristic is kept
  as a fallback for firmware that reports a generic chassis. The priority chain
  is unchanged (`VM > SV > TB > MD > LT > PB > DT`) — an ARM notebook still
  records `MD`, a convertible still records `TB`. Machines whose chassis is
  9/10 but whose model string lacks "Laptop" (most business laptops — Latitude,
  EliteBook, ThinkPad) previously fell through to `DT` and are now correctly
  `LT`.

### Fixed

- **BUG-014** — `launcher.ps1` `Invoke-SelfElevation` wrapped forwarded
  parameter values in single quotes for **both** relaunch paths, but single
  quotes are literal characters to the native command line: on the `-File`
  path (saved script, non-elevated start) string values arrived quote-wrapped,
  values with spaces were split mid-value, and non-string values failed
  parameter binding outright — which would have broken `-PromptTimeoutSeconds`
  on that path. Values are now quoted per relaunch path: double quotes for
  `-File` (the native parser strips them; embedded `"` is already refused by
  the SEC-003 guard), single quotes for the `iex` `-Command` string
  (unchanged). Verified with real `powershell.exe -File` / `-Command`
  round-trips using a spaced path and an `[int]` value. Full write-up in
  DECISIONS.md → Known Bugs.

> **Manifest note:** `logging.ps1`, `device.ps1`, `naming.ps1`, `rename.ps1`,
> and `launcher.ps1` all changed in this release. Anyone deploying with a
> populated `$MANIFEST` must re-run `tools/Get-Hashes.ps1` and paste the full
> block before pinning a new SHA (remember SEC-002: once pinned, any leftover
> placeholder entry is fatal at runtime). The canonical repo keeps
> `REPLACE_WITH_HASH` placeholders as before.

---

## [3.2.0] — 2026-07-10

Feature release. Adds the optional `-Gui` WPF presentation layer (ADR-008) and
the security hardening that came out of its adversarial review (SEC-001 …
SEC-005, recorded in DECISIONS.md → Security Findings). The console flow
without `-Gui` is functionally identical to v3.1.0 — same prompts, same
parameters, same behaviour — and `-NonInteractive` deployments are untouched.
One deliberate behaviour change, from SEC-001: an unpinned launcher
(`$COMMIT_SHA` still the placeholder) now refuses to run instead of silently
fetching unverified code from `main`; production/MDM deployments (pinned SHA,
populated manifest) are unaffected.

### Added

- **`-Gui` — optional WPF presentation layer.** New `gui.ps1` module (loaded after
  `naming.ps1`, before `rename.ps1` — see `$MODULES` in `launcher.ps1`) adds a
  `Show-RenameGui` window that collects the same inputs as the console prompts
  (naming mode, department, type override, profile selection), with a live
  preview built from the same `New-DeviceName` / `New-UserDeviceName` functions
  the console path uses, so the preview can never drift from the name that is
  actually applied. `gui.ps1` never calls `Rename-Computer` itself — `rename.ps1`
  still owns the `ShouldProcess` gate and the rename.
  - `-Gui` + `-NonInteractive` together throw immediately: a GUI cannot exist in
    an unattended run, and silently honouring one of the two would hide a
    deployment mistake (same never-guess-in-automation philosophy as BUG-002).
  - Any precondition failure (non-interactive session, non-STA thread,
    `PresentationFramework` unavailable) or unexpected WPF error returns a
    `$script:GUI_UNAVAILABLE` sentinel and falls back to the existing console
    prompts — a GUI failure must never block a rename.
  - Window close paths: **Rename** and **Dry run** collect inputs and close the
    window (Dry run rides the existing `-WhatIf` rails); **Cancel** and the
    titlebar **X** both leave the result `$null`, handled identically to
    answering `N` at the console confirmation prompt — the window IS the
    confirmation, so there is no second Y/N prompt afterward.
  - Every exit path is logged via `Write-Log` from `rename.ps1` (per ADR-007,
    `gui.ps1` itself never calls `Write-Log`).
  - The XAML is a static, single-quoted here-string — no runtime data (profile
    names, hostnames, serials, WMI model strings) is ever interpolated into it,
    since XAML is executable markup and splicing attacker-influenced strings
    into it would be an injection vector. All values are populated via control
    properties after parsing.
  - `launcher.ps1` gains the `-Gui` switch, forwarded to `Rename-DeviceSmart`.
    `tools/Get-Hashes.ps1` and `$MANIFEST` in `launcher.ps1` both updated to
    include `gui.ps1` in the hashed file list, in the same load-order position.

- **`Resolve-GatewayPreview` (`gui.ps1`).** The Gateway-mode preview logic
  (comparing the untruncated name against the actual result to detect a dropped
  department segment, and reporting the "even the shortened form overflows 15
  chars" error state) is now a standalone, WPF-free, unit-testable function —
  `Update-RenameGuiPreview` only binds its result to controls.

- **`Get-RenameGuiXaml` (`gui.ps1`).** The window XAML is now a standalone
  function returning the markup as a string, so it can be parsed with
  `XamlReader` in a test without needing an interactive/STA session.

- **`tests/Hostname-Rename.Gui.Tests.ps1`.** New Pester v5 file, same
  no-WMI/OS/GUI-dependency conventions as the main suite: `Resolve-GatewayPreview`
  cases, an XAML smoke test guarded by a `PresentationFramework` availability
  check (skips cleanly where WPF is absent, e.g. Server Core CI images), and
  mock-based parameter-contract tests for `Rename-DeviceSmart -Gui` (throws with
  `-NonInteractive`; falls back to the console flow without throwing when GUI
  preconditions fail; forwards identical parameters to the console path when
  `-Gui` is absent). No real WMI call, WPF window, or `Rename-Computer`
  invocation happens in any test.

### Fixed

- **BUG-012** — `logging.ps1` `Write-Log` was flagged by
  `PSAvoidOverwritingBuiltInCmdlets` under PowerShell 7/`pwsh` (not Windows
  PowerShell 5.1). False positive: PSScriptAnalyzer's bundled `core-6.1.0-windows`
  compatibility profile lists a `Write-Log` cmdlet that does not exist on any
  PowerShell edition this project targets (verified via `Get-Command` on both
  PS 7.6 and Windows PowerShell 5.1; ADR-005 — no third-party modules). Suppressed
  inline with justification, per the BUG-009 approach. Found during the `-Gui`
  feature review; unrelated to the GUI code itself — the CI `lint` job's steps
  always run under `pwsh` regardless of the declared matrix leg (see DECISIONS.md
  → Known Bugs → BUG-013), so this warning would have failed every lint run.

### Security

All five findings come from the dedicated threat-hunt pass over the `-Gui`
branch (2026-07-10). The hunt covered the whole run path an elevated launcher
exercises, not just `gui.ps1` — which is why most fixes land outside the GUI
module. Full write-ups with severity and attack scenarios in DECISIONS.md →
Security Findings.

- **SEC-001** · `launcher.ps1` — an unpinned launcher (`$COMMIT_SHA` still
  `REPLACE_WITH_COMMIT_SHA`) previously warned and then fetched every module
  from `main` with **no hash verification, into an elevated process**. It now
  throws by default; the new `-AllowUnverified` switch is the explicit,
  development-only opt-in (and still warns loudly). The guard never fires for
  a correctly pinned production/MDM deployment. This is the release's only
  behaviour change.

- **SEC-002** · `launcher.ps1` — mixed manifests now fail closed: once a real
  commit SHA is pinned, any `$MANIFEST` entry still holding `REPLACE_WITH_HASH`
  aborts the run before anything is fetched. Previously that one module loaded
  silently unverified (placeholder entries skip the hash check) while the rest
  were verified — a partial-integrity gap a half-regenerated manifest opened
  without any visible signal.

- **SEC-003** · `launcher.ps1` — `Invoke-SelfElevation` now refuses to forward
  any parameter value containing a double-quote. Forwarded values are
  single-quoted, but on the `iex` relaunch path the entire command rides inside
  a `-Command "..."` string, where an embedded `"` terminates the string — a
  command-injection primitive that single-quoting cannot neutralise. Windows
  paths, usernames, and the allow-listed dept/type tokens never legitimately
  contain one, so a hard refusal is safe.

- **SEC-004** · `logging.ps1` + `rename.ps1` — a UNC `-LogPath` or `-FolderPath`
  now draws a prominent warning (and, for `-FolderPath`, a WARN log line):
  every log write / profile enumeration authenticates this **elevated** machine
  to the remote SMB host via NTLM — a handshake a hostile share can capture or
  relay. UNC paths remain supported (ADR-007 documents the log-share use case);
  the point is that a coerced or mistyped UNC value is now visible instead of
  leaking silently.

- **SEC-005** · `device.ps1` + `rename.ps1` — `-Username` is now matched as a
  literal substring: wildcard metacharacters (`*`, `?`, `[`) are escaped via
  `[WildcardPattern]::Escape` before the `-like` filter, in both the console
  path (`Get-UserName`) and the GUI's candidate pre-enumeration (kept
  identical), so a metacharacter in the value can no longer select an
  unintended profile — which `-NonInteractive` would then auto-pick as the
  device name. Profile enumeration also switched from `-Path` to `-LiteralPath`.

- **Verified, no change needed** — the static-XAML rule held under adversarial
  review: `Get-RenameGuiXaml` interpolates nothing (zero `$` characters), and
  the Pester assertion added in this release pins that property so a regression
  fails CI.

> **Manifest note:** `gui.ps1` is new and other module files are unchanged, so
> anyone running with a populated `$MANIFEST` must regenerate hashes via
> `tools/Get-Hashes.ps1` before redeploying. The canonical repo keeps
> `REPLACE_WITH_HASH` placeholders, so the CI `manifest` job still exits cleanly
> (it skips validation entirely rather than failing when placeholders are
> present — see DECISIONS.md → Known Bugs → BUG-013). Note the interaction with
> SEC-002: once you pin a real SHA, *every* placeholder entry becomes fatal at
> runtime — regenerate the whole block, not just the new file's line.

---

## [3.1.0] — 2026-06-03

Feature release. Delivers the entire v3.1 backlog and closes two threads left
open by the v3.0.1 CI work (the BUG-011 test-copy gap and the BOM/ASCII churn).
No breaking changes — every existing invocation behaves as before.

### Added

- **`-FolderPath` and `-Username` (BUG-001).** Now implemented across the full
  call chain (`launcher.ps1` → `Rename-DeviceSmart` → `Get-UserName`), no longer
  documentation-only. `-FolderPath` overrides the `C:\Users` profile search root
  (local or redirected path). `-Username` narrows candidates by case-insensitive
  partial match: interactive sessions show the filtered list to choose from,
  NonInteractive picks the most recently active match (throws if nothing matches).
  Either parameter implies User mode via `Select-NamingMode`.

- **`logging.ps1` — run logging (OQ-001).** New module (loaded first) exposing
  `Initialize-Log` and `Write-Log`. Default destination `%TEMP%\Hostname-Rename`,
  overridable with `-LogPath` (local or UNC). Logging is best-effort and **never
  blocks a rename** — init failures warn and disable; write failures are swallowed
  via `-ErrorAction SilentlyContinue`. `Rename-DeviceSmart` logs gateway, context,
  mode, name parts, the proposed name, and the rename/cancel/WhatIf outcome.

- **`-WhatIf` / `SupportsShouldProcess` (OQ-002).** `Rename-DeviceSmart` is now an
  advanced function with `[CmdletBinding(SupportsShouldProcess)]`; the rename is
  gated by `$PSCmdlet.ShouldProcess`. `launcher.ps1` declares `SupportsShouldProcess`
  and forwards `-WhatIf:$WhatIfPreference` so a dry run works through the `iex` /
  scriptblock deployment surface. Under `-WhatIf` the interactive Y/N prompt is
  skipped and the intended rename is reported instead of performed.

- **`TB` device type and `PB` detection (OQ-003).** `Get-DeviceType` adds a fourth
  parallel CIM query (`Win32_SystemEnclosure`). `TB` = Tablet/Convertible
  (`ChassisTypes` 30/31), `PB` = Pizza Box (`ChassisTypes` 5). Both added to
  `$script:DEVICE_TYPES`. Priority: `VM > SV > TB > MD > LT > PB > DT`.

- **WMI-free helper functions** (`device.ps1`): `Resolve-DeviceType` (the device-type
  priority chain), `ConvertTo-SerialLast4` (serial cleaning/padding), and
  `ConvertTo-CleanUserName` (profile-name cleaning). `Get-DeviceType`,
  `Get-SerialLast4`, and `Get-UserName` now delegate to these.

- **Expanded Pester suite.** `ConvertTo-SerialLast4` and `ConvertTo-CleanUserName`
  tests now exercise the **real** functions instead of inline copies (closes the
  BUG-011 testing gap). New `Resolve-DeviceType` block (chain + priority, incl.
  PB/TB) and new `Select-NamingMode` cases for the `-FolderPath`/`-Username`
  precedence. `PB`/`TB` added to the 15-char NetBIOS integration sweep.

### Changed

- **`launcher.ps1`** — `logging.ps1` prepended to `$MODULES` and `$MANIFEST`
  (loads first). `$MANIFEST` is now `[ordered]` to match `Get-Hashes.ps1` output
  for a clean paste. `Invoke-SelfElevation` now single-quotes forwarded parameter
  *values* (doubling embedded quotes) so a value containing spaces — e.g.
  `-FolderPath "D:\User Profiles"` — survives the UAC relaunch on both the `-File`
  and `iex`/`wt.exe` paths. New `-FolderPath`/`-Username`/`-LogPath` params and the
  `-WhatIf` passthrough wired into the final `Rename-DeviceSmart` call.

- **`tools/Get-Hashes.ps1`** — `logging.ps1` added to the hashed file list (first).

- **ASCII-only conversion completes the BUG-009/010 thread.** `network.ps1`,
  `rename.ps1`, and `tests/Hostname-Rename.Tests.ps1` were converted to ASCII
  (em dashes, arrows, and box-drawing replaced with `--`/`->`) and their BOMs
  removed. The repository is now uniformly ASCII; **no file requires a UTF-8 BOM**,
  which retires the entire `PSUseBOMForUnicodeEncodedFile` class of issues. The
  former `$script:`-scope scriptblock workarounds in the test file
  (`PSUseDeclaredVarsMoreThanAssignments` false positive) are gone — the tests call
  the real helpers, so the cross-scope dance is no longer needed.

### Fixed

- **BUG-001 / BUG-004** — closed in code. `-FolderPath`/`-Username` exist and work;
  no longer "planned" in the docs.

- **`naming.ps1`** — `Select-NamingMode` `.SYNOPSIS` corrected from "15-second" to
  the actual 8-second timeout (a stale docstring edit carried in from v3.0.1).

> **Manifest note:** module file contents changed (new module, edits, BOM removal),
> so anyone running with a populated `$MANIFEST` must regenerate hashes via
> `tools/Get-Hashes.ps1` before redeploying. The canonical repo keeps
> `REPLACE_WITH_HASH` placeholders, so the CI `manifest` job still exits cleanly.

---

## [3.0.1] -- 2026-05-02

CI hygiene patch release. No runtime behaviour changes -- all fixes are linter
compliance, encoding correctness, test scaffolding, and supporting documentation.
Six latent issues in the v3.0.0 CI pipeline surfaced sequentially as each fix
unblocked the next failure (see DECISIONS.md -> BUG-008 "Meta-lesson" for the
chain). One real encoding bug (BUG-009 BOM) was identified and fixed in the
process. BUG-010 captures a practical lesson about ASCII-only justifications.
BUG-011 surfaced once the test job actually ran for the first time since CI
was added.

### Fixed

- **BUG-006** · `.github/workflows/ci.yml` — `placeholder` job step now sets
  `shell: bash` explicitly. The workflow has a global `defaults.run.shell: pwsh`,
  which the `placeholder` job inherited despite running on `ubuntu-latest` with a
  bash one-liner (`if grep -q ...; then ... fi`). pwsh tried to parse the bash
  `if` as a PowerShell `if` statement and failed before grep ran with
  `Missing '(' after 'if' in if statement.` The bug was masked on `main` by the
  `continue-on-error: true` guard from ADR-002 — every push to `main` looked
  green even though the placeholder check had never actually executed since CI
  was added. Fixed by overriding `shell: bash` on that single step; the global
  `pwsh` default is retained for the three Windows-based jobs that need it.

- **BUG-007** · `tools/Get-Hashes.ps1` — eight `Write-Host` calls (the manifest
  block header and "Next steps" footer) replaced with bare-string expressions to
  clear `PSAvoidUsingWriteHost` warnings from the `lint` CI job. As a side
  benefit, this fixes a latent redirection bug: the script was previously
  inconsistent — the framing went through `Write-Host` while the actual hash
  lines went to the success stream — so `.\tools\Get-Hashes.ps1 > manifest.txt`
  silently dropped the framing and captured only the hash lines. With everything
  on the success stream now, redirection captures the complete pasteable block.
  Console behaviour for interactive runs is unchanged.

- **BUG-008** · `.github/workflows/ci.yml` — `test` job's Pester invocation now
  sets `$cfg.Run.PassThru = $true` on the configuration object and calls
  `Invoke-Pester -Configuration $cfg` without `-PassThru`. In Pester v5,
  `-Configuration` and `-PassThru` belong to mutually exclusive parameter sets;
  combining them fails parameter-set resolution before any test runs
  (`Parameter set cannot be resolved using the specified named parameters`).
  The bug had been latent since CI was added in v3.0.0 — the `test` job
  declares `needs: lint`, so while `lint` was failing under BUG-007 the `test`
  job was being **skipped** rather than failing, and the CI looked
  broken-but-explained for an unrelated reason. Surfaced as soon as lint was
  fixed and `test` ran for the first time.

- **BUG-009** · Multiple files — analyzer warnings cleared without compromising
  intent. The `lint` job, finally able to scan the full codebase after BUG-007
  unblocked it, surfaced four categories of warning:
  - `PSAvoidUsingWriteHost` — flagged 9 calls in `device.ps1`, `naming.ps1`, and
    `rename.ps1`. All are interactive prompts paired with `Read-Host` and
    correctly target the host stream rather than success — capturing them
    downstream would defeat the purpose. Suppressed per-function via
    `[Diagnostics.CodeAnalysis.SuppressMessageAttribute]` with justifications
    documented inline. No project-level settings file was added (see DECISIONS.md
    BUG-009 rationale).
  - `PSUseShouldProcessForStateChangingFunctions` — flagged `New-DeviceName` and
    `New-UserDeviceName` in `naming.ps1`. False positive: both are pure
    string-builder functions that take parameters and return a string; the verb
    `New-` is correct (the function produces a new value). Suppressed per-function
    with justification. The same rule will *correctly* fire against
    `Rename-DeviceSmart` once OQ-002 (`SupportsShouldProcess`/`-WhatIf`) is
    implemented in v3.1; that suppression is deliberately *not* applied so the
    warning surfaces when relevant.
  - `PSUseBOMForUnicodeEncodedFile` — flagged `network.ps1`, `rename.ps1`, and
    `tests/Hostname-Rename.Tests.ps1`. Real fix, not suppression: all three files
    contain non-ASCII characters (em dashes, fancy quotes, box-drawing dividers)
    but lacked a UTF-8 byte-order mark. Windows PowerShell 5.1 reads BOM-less
    files as Latin-1 by default and would garble those characters. All three
    files re-saved as UTF-8 with BOM (bytes `EF BB BF` prepended).
  - `PSUseDeclaredVarsMoreThanAssignments` — flagged `$clean` in
    `tests/Hostname-Rename.Tests.ps1` line 157. False positive caused by
    cross-scope reference in Pester (variable declared in `BeforeAll`, used in
    `It` blocks). Fixed properly by promoting the variable to `$script:` scope,
    which is also semantically more correct — Pester's scope inheritance happens
    to make the original code work, but `$script:` makes the cross-scope intent
    explicit. All 8 `It` block call sites updated.

  Note for anyone who has populated `$MANIFEST` in `launcher.ps1` with real
  hashes: `network.ps1` and `rename.ps1` content changed (BOM bytes added), so
  manifest hashes for those two files need to be regenerated via
  `tools/Get-Hashes.ps1` before re-deployment. The canonical repo's `$MANIFEST`
  uses `REPLACE_WITH_HASH` placeholders, so the CI `manifest` job exits cleanly
  with no check performed.

- **BUG-010** · `launcher.ps1` + `device.ps1` + `naming.ps1` — two more analyzer
  warnings surfaced after BUG-009. (1) `PSUseUsingScopeModifierInNewRunspaces`
  flagged `$u` on lines 138–139 of `launcher.ps1`, inside a `Start-Job` script
  block. False positive: the variable IS declared inside the block via
  `param($u)` and the value is passed in via `-ArgumentList $url`, which is the
  idiomatic and preferred pattern (switching to `$using:` would be a regression).
  Resolution: file-level `[SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', ...)]`
  on `launcher.ps1`'s top param block with justification. (2)
  `PSUseBOMForUnicodeEncodedFile` flagged `device.ps1` and `naming.ps1` — both
  files were ASCII-only in v3.0.0 but the BUG-009 SuppressMessage justification
  strings I added contained em dashes (U+2014), pushing them into "non-ASCII file
  needs BOM" territory. Resolution: replaced 2 em dashes in `device.ps1` and 3 in
  `naming.ps1` with `--`, returning both files to ASCII-only and clearing the
  warning. **Practical lesson — keep new code ASCII-only unless the file already
  contains non-ASCII content.**

- **BUG-011** · `tests/Hostname-Rename.Tests.ps1` — five Pester test failures
  cleared. Two distinct issues, both pre-existing in v3.0.0 but masked because
  the test job had never actually run (BUG-008 chain): an orphan `InModuleScope`
  call missing its required `-ModuleName`, and a `$fn` helper declared at
  `Context` (discovery) scope but used in `It` (run) scope. Both resolved by
  wrapping the helper in `BeforeAll { $script:fn = ... }`. A `# TODO (v3.1)` was
  added noting that `Get-SerialLast4` should be refactored so the cleaning logic
  lives in a WMI-free helper the tests can call directly — **done in v3.1 via
  `ConvertTo-SerialLast4`.**

### Changed

- **`.github/workflows/ci.yml`** — bumped `actions/checkout@v4` → `@v6`
  (4 occurrences) and `actions/upload-artifact@v4` → `@v7` to clear the Node.js
  20 deprecation warning surfaced in workflow runs.

---

## [3.0.0] — 2026-04-30

First public / open-source release. Audited from v2 and cleaned for GitHub.
Date updated from 2026-04-28 to 2026-04-30 to reflect pre-launch audit fixes applied before tagging.

### Added

- **`tests/Hostname-Rename.Tests.ps1`** — Pester v5 unit test suite covering all pure-logic
  functions: `New-DeviceName` (name construction and truncation), `New-UserDeviceName`,
  `Get-SerialLast4` (cleaning and padding), `Get-UserName` UPN cleaning steps,
  `Select-NamingMode` switch precedence, `Get-NetworkContext` mapping and fallback, and a
  full integration check of the 15-character NetBIOS limit across all valid
  department/type combinations. No WMI or OS dependency — runs in CI without a real device.

- **`.github/workflows/ci.yml`** — four-job CI pipeline (OQ-005, ADR-002):
  `lint` (PSScriptAnalyzer, PS 5.1 + 7.x matrix), `test` (Pester v5 + NUnit XML
  artifact), `manifest` (recomputes module SHA-256 and compares to `$MANIFEST`),
  and `placeholder` (fails branches still containing `REPLACE_WITH_COMMIT_SHA`;
  `continue-on-error: true` on `main` only).

- **`CONTRIBUTING.md`** — deployment workflow, customisation points, local test
  instructions, PR process, code style requirements, and a v3.1 planned work table.

### Fixed

- **BUG-005** · `network.ps1` — `Get-NetworkContext` now opens with an
  `[string]::IsNullOrEmpty` guard before the map lookup, with a clear "no default
  gateway was detected" message that is always fatal regardless of interactive mode.

- **BUG-003** · `device.ps1` — CIM job objects in `Get-DeviceType` cleaned up
  reliably via a `$jobs` array + single `finally`. (Described in the initial v3
  audit but found unapplied in the pre-launch code audit on 2026-04-30; applied then.)

- **BUG-002** · `network.ps1` / `rename.ps1` — hardcoded `RS` fallback ORG replaced
  with a configurable `$script:FALLBACK_CONTEXT` (`XX`/`99`/`X`); `Get-NetworkContext`
  gained `-NonInteractive` (throw in automation, warn prominently interactively),
  forwarded from `Rename-DeviceSmart`.

- **BUG-001 / BUG-004** · `README.md` — `-Folder` corrected to document `C:\Users`
  profile selection; `-FolderPath`/`-Username` marked *(planned — v3.1)*.

### Changed

- **`network.ps1`** — internal `10.72.x.x` gateways replaced with RFC 5737
  documentation ranges; example ORG changed to `AC`; `# -- CONFIGURE YOUR SITES HERE --`
  block added.

- **`README.md`** — RFC 5737 example IPs, explicit ORG two-character constraint,
  Valid Codes section, log-share requirement removed, `PB` listed as planned v3.1,
  `CONTRIBUTING.md` reference added.

### Architecture decisions recorded

| ADR | Decision |
|---|---|
| ADR-001 | Module loading model: remote fetch + dot-source (carry forward from v2) |
| ADR-002 | Pin deployments to full 40-character commit SHA, never `main` |
| ADR-003 | Two naming modes — Gateway `{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}` and User `{WH}{LOC}-{Name}` |
| ADR-004 | Organisation data lives in `network.ps1`; example data uses RFC 5737 IPs |
| ADR-005 | No external dependencies — built-in cmdlets and .NET types only |
| ADR-006 | ORG code constrained to exactly two characters (15-char NetBIOS hostname limit) |

---

## [2.0.0] — internal, not publicly released

Functional version used in internal deployments. Carried forward the core architecture
(parallel module fetching, SHA-256 manifest check, self-elevation with UAC-hop parameter
forwarding, parallel CIM queries) with the following known issues — all resolved in v3.0.0:

- Hardcoded internal gateway IPs and org-specific `RB` fallback code
- README documented `-FolderPath` and `-Username` parameters that were not implemented
- `-Folder` mode described as reading Desktop subfolders; implementation read `C:\Users`
- CIM job objects in `Get-DeviceType` leaked if a query threw before `Remove-Job` was reached
- `Get-NetworkContext` silently returned the `RS` fallback ORG on any unrecognised gateway,
  including during non-interactive / MDM deployments where a wrong name is worse than a failure

---

[Unreleased]: https://github.com/3aruin/Hostname-rename/compare/v3.8.0...HEAD
[3.8.0]: https://github.com/3aruin/Hostname-rename/compare/v3.3.0...v3.8.0
[3.3.0]: https://github.com/3aruin/Hostname-rename/compare/v3.2.0...v3.3.0
[3.2.0]: https://github.com/3aruin/Hostname-rename/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/3aruin/Hostname-rename/compare/v3.0.1...v3.1.0
[3.0.1]: https://github.com/3aruin/Hostname-rename/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/3aruin/Hostname-rename/releases/tag/v3.0.0
