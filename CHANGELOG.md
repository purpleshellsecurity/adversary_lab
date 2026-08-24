# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`-Action Test` verb** - Both tooling scripts can now report whether components are configured *and* whether events are actually being produced, without changing anything. Exits `2` when unhealthy so automation can gate on it.
- **Install manifests** - `C:\ProgramData\AdversaryLab\{blue,red}team-state.json` record what each install actually changed. `-Action Remove` reverses only those changes, restoring prior audit settings and registry values instead of guessing at Windows defaults.
- **Deploy-time telemetry verification** - `adversary_lab_deploy.ps1` now probes the guest for a running Azure Monitor Agent and waits for a real `Heartbeat` row before declaring success. Opt out with `-SkipTelemetryCheck`; tune with `-TelemetryTimeoutMinutes`.
- **Plan mode** - `-WhatIf` renders the intended per-component change set before gating every mutation.

### Changed
- **Blue/Red team scripts merged** - `Install-*`/`Uninstall-*` pairs replaced by `AdversaryLab-BlueTeam.ps1` and `AdversaryLab-RedTeam.ps1`, each with `-Action Install|Remove|Test`. Components declare Test/Install/Remove once in a table; the three verbs are three walks over it, so they cannot drift apart. Red team's Remove walks the table in reverse.
- **Credentials are saved immediately after the VM is created**, not after every subsequent deployment step. Previously a failure in the activity-log, flow-log or budget step lost an auto-generated password permanently, along with access to a VM that was already running.
- **AzureHound is added to the machine PATH** - previously only `$env:Path` was modified, so it was never actually available after a restart despite the installer claiming otherwise.
- **TLS 1.2 is set before the first PSGallery call** rather than midway through installation.
- **CI lint rules tightened** - `PSShouldProcess`, `PSUseShouldProcessForStateChangingFunctions` and `PSUseApprovedVerbs` are now enforced; per-function exceptions use targeted `[SuppressMessageAttribute]` with justifications.

### Fixed
- **`-Force` was silently ignored** when Sysmon was already running. `if (Test-SysmonRunning -and -not $Force)` binds `-and`/`-not` as arguments to the function and discards the check, so Sysmon could never be reinstalled or reconfigured in place.
- **`-WhatIf` was advertised but not honored** by either installer. Both declared `SupportsShouldProcess` with zero `ShouldProcess` calls, so `-WhatIf` installed a kernel driver and rewrote audit policy while appearing to preview. The blue-team uninstaller also deleted Sysmon driver files outside its `ShouldProcess` guard.
- **`Install-BlueTeamTools` could not run unattended** - the confirmation prompt was not gated by `-Force`, which blocked Custom Script Extension and `Invoke-AzVMRunCommand` use.
- **Array unrolling under StrictMode** - `return @()` unrolls to `$null`, so `.Count` threw and broke `-Action Remove` whenever no state file existed.
- **Remove-then-reinstall deadlock** - a removed-but-locked `Sysmon64.exe` blocked reinstall and aborted the whole run. The existing binary is now reused and its queued reboot-deletion cancelled.
- **One failing component no longer aborts the others** - components are independent; failures are collected and surfaced in the exit code.
- **Elevation used a hardcoded `pwsh.exe`** that does not exist on a fresh Windows 11 image. Now uses the running host.
- **Azure Monitor Agent detection** - AMA does not always register a Windows service; a service-only probe reported a false negative on a healthy agent. Now checks service, processes and extension package, and distinguishes "running" from "installed but not running".
- **Uninstall no longer removes software it did not install** - `-KeepPython`/`-KeepGit` are unnecessary; pre-existing git, Python and Defender exclusions are left alone.

### Removed
- `Install-BlueTeamTools.ps1`, `Uninstall-BlueTeamTools.ps1`, `Install-RedTeamTools.ps1`, `Uninstall-RedTeamTools.ps1` - superseded by the merged scripts.

## [2.0.0] - 2025-12-28

### Added
- **Automated VNet Flow Logs** - Flow logs now deploy automatically via `network_monitoring.bicep` (previously required manual portal configuration)
- **Storage module** - New `storage.bicep` for flow log storage account
- **Blue Team Tools installer** - `Install-BlueTeamTools.ps1` combines Sysmon, PowerShell logging, and Windows audit policies into a single configurable script
- **Red Team Tools installer** - `Install-RedTeamTools.ps1` installs Azure/Entra ID security assessment tools (AADInternals, GraphRunner, AzureHound, etc.)
- **Uninstall scripts** - `Uninstall-BlueTeamTools.ps1` and `Uninstall-RedTeamTools.ps1` for clean removal
- **CONTRIBUTING.md** - Architecture documentation and contributor guidelines
- **CHANGELOG.md** - Version history tracking

### Changed
- **Module reorganization** - All Bicep modules moved to `modules/` directory with clear separation of concerns
- **VM size** - Updated default from `Standard_D2s_v3` to `Standard_D2s_v4`
- **README overhaul** - Cleaner structure, GitHub alert callouts, removed redundant sections
- **Scripts consolidated** - Individual scripts (`Enable-PSLogging.ps1`, `Install-Sysmon.ps1`) replaced by unified BlueTeam/RedTeam installers

### Removed
- **Stratus Red Team** - Removed from deployment and documentation
- **Manual flow log setup** - No longer needed (now automated)
- **Individual setup scripts** - Replaced by consolidated installers

### Fixed
- Network Watcher creation now handled automatically before flow log deployment

## [1.0.0] - 2025-07-29

### Added
- Initial release
- Windows 11 Pro VM with Azure Monitor Agent
- Microsoft Sentinel with 12+ security solutions
- Log Analytics Workspace
- Data Collection Rules for VM monitoring
- Azure Activity Logs integration
- Network Security Groups with RDP restriction
- Auto-shutdown scheduling
- Budget alerts
- Manual setup scripts for Sysmon, PowerShell logging, and Stratus Red Team