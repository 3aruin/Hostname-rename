# Hostname-Rename

Renames Windows devices to a standard naming convention, delivered via a single `iwr | iex` command from GitHub.

---

## Overview

Automates Windows device naming based on:

- **Location** — resolved from gateway address
- **Department** — prompted at runtime (or passed via parameter)
- **Device Type** — auto-detected
- **Serial Number** — pulled from hardware

---

## Repo Structure

```
Hostname-rename/
├── launcher.ps1        # Entry point — fetches, verifies, and runs everything
├── network.ps1         # Gateway map and network/folder context resolution
├── device.ps1          # Device type detection, department, and serial number
├── naming.ps1          # Naming mode selection and name construction
├── rename.ps1          # Rename-DeviceSmart orchestrator
└── tools/
    └── Get-Hashes.ps1  # Local helper — regenerates manifest hashes
```

---

## Name Format

```
{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}
```

**Example:** `RB01R-WSDT-A3F9`

| Segment | Description |
|---|---|
| `{ORG}` | Organization abbreviation |
| `{WH}` | Two-digit warehouse number |
| `{LOC}` | Single location letter |
| `{DEPT}` | Department code |
| `{TYPE}` | Workstation/system type |
| `{SERIAL}` | Last four characters of serial number |

> If the full name exceeds 15 characters, the department segment is automatically dropped:
> `{ORG}{WH}{LOC}-{TYPE}-{SERIAL}`

---

## Requirements

- Windows with PowerShell
- Administrator privileges
- Network access to log share *(optional)*

---

## First-Time Setup

### 1. Set your repo URL

In `launcher.ps1`, confirm the repo base is set correctly:

```powershell
$REPO_BASE = "https://raw.githubusercontent.com/3aruin/Hostname-rename"
```

### 2. Add your sites

In `network.ps1`, extend the `$GATEWAY_MAP` with your site entries:

```powershell
$script:GATEWAY_MAP = @{
    "10.72.0.1" = @{ ORG = "RB"; WH = "00"; LOC = "A" }
    # Add additional sites here
}
```

### 3. Generate hashes and pin to a commit

After any change to module files, regenerate the manifest from the repo root:

```powershell
.\tools\Get-Hashes.ps1
```

Paste the output into the `$MANIFEST` block in `launcher.ps1`, commit all changes, and note the resulting commit SHA.

> ⚠️ **Always pin to a full commit SHA in your deployment URL — never use `main` directly.**

---

## Running

### Interactive

```powershell
iex (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
```

### With Parameters

```powershell
& ([scriptblock]::Create(
    (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
)) -NonInteractive -Gateway
```

### Available Parameters

| Parameter | Type | Description |
|---|---|---|
| `-Gateway` | switch | Force gateway-based naming |
| `-Folder` | switch | Force folder-based naming (reads Desktop subfolders) |
| `-FolderPath` | string | Custom path for folder mode (default: user's Desktop) |
| `-Username` | string | Partial username to match for profile path resolution |
| `-NonInteractive` | switch | No prompts — for MDM/automated deployment |

---

## Deployment Workflow

Follow these steps after any change to module files:

1. Edit module files as needed
2. Run `.\tools\Get-Hashes.ps1` and paste the output into the `$MANIFEST` block in `launcher.ps1`
3. Commit all changes
4. Copy the new commit SHA
5. Update your deployment script or MDM command with the new SHA in the URL

---

## Usage Notes

- Run **as needed** to standardize device names across the network
- Helps clean up network visibility and supports remote team management
- Silent/MDM deployment is supported via `-NonInteractive`
