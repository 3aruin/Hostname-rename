## ✅ Why

### 💻 Device Rename Script

## Overview
Automates Windows device naming based on:
- Location (Based on Gateway address)
- Department (Will need input)
- Device Type
- Serial Number



## 💡 Usage
*As needed
*Will help clean up network to help remote teams

### Interactive
```powershell
.\Rename-Computer.ps1
````

### Silent / IRM Deployment

```powershell
.\Rename-Computer.ps1 -NonInteractive
```
### Launch Command

#### Stable Branch (Recommended)

```ps1
irm "https://raw.githubusercontent.com/user/repository/branch/filename.ps1" | iex
```

## 🛠️ Requirements

* Admin privileges
* Network access to log share (optional)

## 🏭 Output Format

[Organization][Warehouse Number Two Digit][Location Letter]-[Department][Type of workstations/system]-[Last four Serial number]

[ORG][Whse#][LOC]-[DEPT][TYPE]-[S#ØØ]


DeviceRename
Renames Windows devices to a standard naming convention, delivered via a single `iwr | iex` command from GitHub.
Repo Structure
```
DeviceRename/
├── launcher.ps1        # Entry point — fetches, verifies, and runs everything
├── network.ps1         # Gateway map, network/folder context resolution
├── device.ps1          # Device type detection, department, serial number
├── naming.ps1          # Naming mode selection, name construction
├── rename.ps1          # Rename-DeviceSmart orchestrator
└── tools/
    └── Get-Hashes.ps1  # Local helper — regenerates manifest hashes
```
---
First-Time Setup
1. Set your repo URL
In `launcher.ps1`, update:
```powershell
$REPO_BASE = "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO"
```
2. Add your sites
In `network.ps1`, extend `$GATEWAY_MAP`:
```powershell
$script:GATEWAY_MAP = @{
    "10.72.0.1" = @{ ORG = "RB"; WH = "00"; LOC = "A" }
    # add new sites here
}
```
3. Generate hashes and pin to a commit
After any change to module files:
```powershell
cd YOUR_REPO_ROOT
.\tools\Get-Hashes.ps1
```
Paste the output into the `$MANIFEST` block in `launcher.ps1`, then commit everything. Note the resulting commit SHA.
---
Running
Interactive
```powershell
iex (iwr "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/COMMIT_SHA/launcher.ps1").Content
```
With parameters
```powershell
& ([scriptblock]::Create(
    (iwr "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/COMMIT_SHA/launcher.ps1").Content
)) -NonInteractive -Gateway
```
Available parameters
Parameter	Type	Description
`-Gateway`	switch	Force gateway-based naming
`-Folder`	switch	Force folder-based naming (reads Desktop subfolders)
`-FolderPath`	string	Custom path for folder mode (default: user's Desktop)
`-Username`	string	Partial username to match for profile path resolution
`-NonInteractive`	switch	No prompts — for MDM/automated deployment
---
Name Format
```
{ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}
```
Example: `RB01R-WSDT-A3F9`
If the full name exceeds 15 characters, department is dropped:
```
{ORG}{WH}{LOC}-{TYPE}-{SERIAL}
```
---
Deployment Workflow (after any change)
Edit module files
Run `.\tools\Get-Hashes.ps1` → copy output into `launcher.ps1`
Commit all changes
Copy the commit SHA
Update your deployment script/MDM command with the new SHA in the URL
> **Never point your iwr URL at `main`** — always use a full commit SHA.
