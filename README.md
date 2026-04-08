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
