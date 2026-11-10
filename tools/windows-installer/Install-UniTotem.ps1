<#
.SYNOPSIS
Prepares a Windows 10/11 UEFI PC to boot the UniTotem OTA environment once; the host then installs UniTotem
over the network and the disk is erased. Run elevated (Safe Mode is fine). PowerShell 5.1.
.PARAMETER AuthorizedKey  File with one ssh-ed25519 public key line (arms the OTA login). Without it the
                          environment is in open mode: the empty root password is accepted from the network.
.PARAMETER WhatIf         Print the plan, change nothing.
.PARAMETER Undo           Remove the boot entry, the files and the partition created by this script.
.PARAMETER PayloadDir     Folder with the payload (default: .\payload next to the script).
.PARAMETER Unattended     No prompts, no window: needs -Disk and -ConfirmToken. -WhatIf -Unattended records the
                          expected token in the status file. Exit codes: see $Script:Exit.
.PARAMETER Disk           Number of the system disk (unattended).
.PARAMETER ConfirmToken   WIPE-<HOST>-DISK<number>-<first 8 characters of the disk serial> (unattended).
.PARAMETER Reboot         Restart into the OTA environment when ready (unattended).
.PARAMETER Remote         Served by tools/win-install-server.py (irm URL | iex): read-only inventory, wait for the host's
                          approval, then download the payload and prepare. Server/PayloadSha256/PayloadBytes/
                          PollSeconds/TimeoutMinutes come from the bootstrap.
#>
[CmdletBinding()]
param(
    [string]$AuthorizedKey,
    [switch]$WhatIf,
    [switch]$Undo,
    [string]$PayloadDir,
    [ValidateRange(1, 1440)][int]$DecryptTimeoutMinutes = 240,
    [switch]$Unattended,
    [ValidateRange(0, 9999)][int]$Disk = -1,
    [string]$ConfirmToken,
    [switch]$Reboot,
    [switch]$Remote,
    [string]$Server,
    [string]$PayloadSha256,
    [long]$PayloadBytes = 0,
    [ValidateRange(1, 60)][int]$PollSeconds = 5,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 60,
    [ValidateRange(1, 120)][int]$DownloadTimeoutMinutes = 10
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$Script:Label = 'UNITOTEMOTA'
$Script:EntryName = 'UniTotem OTA'
$Script:EspDir = 'EFI\unitotem'
$Script:BiosDir = 'unitotem'
$Script:BiosImage = 'unitotem-g2.img'
$Script:ChainFiles = @('shimx64.efi', 'mmx64.efi', 'grubx64.efi')
$Script:MinPartBytes = 256MB
$Script:HeadroomBytes = 64MB
$Script:ShrinkMarginBytes = 64MB
$Script:EspMarginBytes = 16MB
# Folder of the script, or a work folder when the code runs from memory (irm | iex).
$Script:Here = $null
try { if ($MyInvocation.MyCommand.Path) { $Script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path } } catch { }
if (-not $Script:Here) {
    $Script:Here = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'UniTotem-install'
    New-Item -ItemType Directory -Path $Script:Here -Force | Out-Null
}
$Script:LogFile = Join-Path $Script:Here 'Install-UniTotem.log'
$Script:StateFile = Join-Path $Script:Here 'Install-UniTotem.state.json'
$Script:StatusFile = Join-Path $Script:Here 'Install-UniTotem.status.json'
$Script:Exit = @{ Ok = 0; Failed = 1; Usage = 2; NotAdmin = 3; Unsupported = 4; NotConfirmed = 5; Payload = 6; DecryptTimeout = 7; NoApproval = 8; Server = 9 }
$Script:Status = [ordered]@{ Result = 'running'; Code = -1; Message = ''; Step = ''; Mode = ''; DiskNumber = $null; DiskSerial = ''; DiskModel = ''; Where = ''; Partition = ''; BootEntry = ''; ExpectedToken = ''; DryRun = [bool]$WhatIf; Time = '' }
# Parameters as script state, so functions never depend on the caller's scope.
$Script:Opt = @{ WhatIf = [bool]$WhatIf; Undo = [bool]$Undo; Unattended = [bool]$Unattended; Reboot = [bool]$Reboot; Disk = $Disk; ConfirmToken = $ConfirmToken; AuthorizedKey = $AuthorizedKey; PayloadDir = $PayloadDir; DecryptTimeoutMinutes = $DecryptTimeoutMinutes; Remote = [bool]$Remote; Server = $Server; PayloadSha256 = $PayloadSha256; PayloadBytes = $PayloadBytes; PollSeconds = $PollSeconds; TimeoutMinutes = $TimeoutMinutes; DownloadTimeoutMinutes = $DownloadTimeoutMinutes; MachineId = '' }
$Script:Re = @{
    Server  = 'http://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{2,5}'
    MachineId = '[A-Za-z0-9-]{8,64}'
    Guid    = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
    Letter  = '[A-Z]'
    Number  = '[0-9]{1,4}'
    Ed25519 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}( [\x21-\x7E][\x20-\x7E]{0,127})?'
    Base64  = '[A-Za-z0-9+/=]{1,1024}'
    Hash    = '[0-9a-f]{64}'
    FileName = '[A-Za-z0-9._-]{1,64}'
    GrubDir = '(/[A-Za-z0-9._-]{1,64}){0,4}'
}

# ---- pure helpers (unit tested) ----------------------------------------------------------------------------

# Whole-string match (fullmatch): \A ... \z, never a substring.
function Test-FullMatch {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Pattern)
    if ($null -eq $Value) { return $false }
    return [regex]::IsMatch($Value, '\A(?:' + $Pattern + ')\z')
}

# First {GUID} token of bcdedit output, validated; $null when there is none (output is localized, the token is not).
function Get-BcdGuid {
    param([string[]]$Output)
    $m = [regex]::Match(($Output -join "`n"), $Script:Re.Guid)
    if ($m.Success -and (Test-FullMatch $m.Value $Script:Re.Guid)) { return $m.Value }
    return $null
}

# Partition size for the payload: at least 256 MiB, payload + 64 MiB headroom, rounded up to 16 MiB.
function Get-PartitionBytes {
    param([Parameter(Mandatory)][long]$PayloadBytes)
    $need = $PayloadBytes + $Script:HeadroomBytes
    $step = 16MB
    $size = [long]([math]::Ceiling($need / $step) * $step)
    if ($size -lt $Script:MinPartBytes) { $size = [long]$Script:MinPartBytes }
    return $size
}

# C: can give up NeededBytes when SizeNow - SizeMin leaves the needed space plus a margin.
function Test-ShrinkFeasible {
    param([long]$SizeNow, [long]$SizeMin, [long]$NeededBytes)
    return (($SizeNow - $SizeMin) -ge ($NeededBytes + $Script:ShrinkMarginBytes))
}

# One ssh-ed25519 line from key file lines; $null when not exactly one valid line.
function Get-KeyLine {
    param([string[]]$Lines)
    $keys = @($Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    if ($keys.Count -ne 1) { return $null }
    if (-not (Test-FullMatch $keys[0] $Script:Re.Ed25519)) { return $null }
    return $keys[0]
}

# unitotem.ota.authkey token: base64 of the "ssh-ed25519 BLOB" pair (comment dropped), as the deploy tool sends it.
function ConvertTo-AuthKeyToken {
    param([Parameter(Mandatory)][string]$KeyLine)
    if (-not (Test-FullMatch $KeyLine $Script:Re.Ed25519)) { throw 'invalid key line' }
    $pair = ($KeyLine -split ' ')[0..1] -join ' '
    $tok = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    if (-not (Test-FullMatch $tok $Script:Re.Base64)) { throw 'invalid token' }
    return $tok
}

# grub.cfg from the template. Substituted values are validated: the key token, and the paths of the files.
function New-GrubCfg {
    param([Parameter(Mandatory)][string]$Template, [string]$Token, [string]$Dir = '')
    $extra = ''
    if ($Token) {
        if (-not (Test-FullMatch $Token $Script:Re.Base64)) { throw 'invalid token' }
        $extra = ' unitotem.ota.authkey=' + $Token
    }
    if ($Dir -ne '' -and -not (Test-FullMatch $Dir $Script:Re.GrubDir)) { throw 'invalid directory' }
    return $Template.Replace('@AUTHKEY@', $extra).Replace('@DIR@', $Dir)
}

# Where the boot files go: the unencrypted boot partition (ESP / System Reserved) when everything fits with a
# margin, else a new FAT32 partition carved from C:.
function Get-StorageChoice {
    param([long]$FreeBytes, [long]$NeededBytes)
    if ($FreeBytes -ge ($NeededBytes + $Script:EspMarginBytes)) { return 'boot' }
    return 'new'
}

# Parses a SHA256SUMS text into @{name = hash}; any malformed line is an error.
function Read-Sums {
    param([string[]]$Lines)
    $h = @{}
    foreach ($l in $Lines) {
        if ($l.Trim() -eq '') { continue }
        $m = [regex]::Match($l, '\A([0-9a-f]{64})  ([A-Za-z0-9._-]{1,64})\z')
        if (-not $m.Success) { throw ('malformed checksum line: ' + $l) }
        $h[$m.Groups[2].Value] = $m.Groups[1].Value
    }
    return $h
}

# Free drive letter from Z down to D, never in $Used.
function Get-FreeLetter {
    param([string[]]$Used)
    foreach ($c in [char[]](90..68)) {
        $s = [string]$c
        if ($Used -notcontains $s) { return $s }
    }
    throw 'no free drive letter'
}

# Confirmation word for a disk: WIPE-<HOST>-DISK<number>-<first 8 alphanumerics of the serial, upper case>.
# HOST: computer name, upper case, only A-Z 0-9 -, 15 characters at most.
function Get-ConfirmWord {
    param([string]$HostName, [int]$Number, [string]$Serial)
    $h = ([regex]::Replace(("" + $HostName).ToUpperInvariant(), '[^A-Z0-9-]', ''))
    if ($h.Length -gt 15) { $h = $h.Substring(0, 15) }
    $clean = ([regex]::Replace(("" + $Serial), '[^A-Za-z0-9]', '')).ToUpperInvariant()
    if ($clean.Length -gt 8) { $clean = $clean.Substring(0, 8) }
    if ($clean.Length -eq 0) { $clean = 'NOSERIAL' }
    return ('WIPE-' + $h + '-DISK' + $Number + '-' + $clean)
}

# Ordered list of plan lines (text only; the executor runs the same steps). Ctx.Where: boot | new.
function Build-Plan {
    param([hashtable]$Ctx)
    $p = New-Object System.Collections.Generic.List[string]
    if ($Ctx.Undo) {
        $p.Add('Remove the boot entry "' + $Script:EntryName + '" (boot manager and one-shot)')
        if ($Ctx.Mode -eq 'bios') {
            $p.Add('Remove the folder ' + $Script:BiosDir + ' and ' + $Script:BiosImage + ' from the boot partition')
        } else {
            $p.Add('Remove ' + $Script:EspDir + ' from the EFI system partition')
        }
        $p.Add('Remove the partition labelled ' + $Script:Label + ' and extend C: again, if one was created')
        return , $p
    }
    $mb = [math]::Round($Ctx.PartBytes / 1MB)
    $need = [math]::Round($Ctx.NeededBytes / 1MB)
    if ($Ctx.Where -eq 'boot') {
        $p.Add('Put the boot files (' + $need + ' MiB) on the boot partition: C: and BitLocker are not touched')
    } elseif ($Ctx.Where -eq 'cdrive') {
        $p.Add('Put the boot files (' + $need + ' MiB) in C:\' + $Script:BiosDir + ': no partition change, only file copies and bcdedit')
    } else {
        $p.Add('Shrink C: by ' + $mb + ' MiB (the boot partition has too little space)')
        $p.Add('Create a FAT32 partition labelled ' + $Script:Label + ' (' + $mb + ' MiB) and turn BitLocker off on it only')
        $p.Add('Put the boot files on it')
    }
    if ($Ctx.Mode -eq 'bios') {
        $p.Add('Copy the GRUB loader to the boot partition as ' + $Script:BiosImage)
    } else {
        $p.Add('Copy ' + ($Script:ChainFiles -join ', ') + ' and grub.cfg to ' + $Script:EspDir + ' on the EFI system partition')
    }
    if ($Ctx.Token) { $p.Add('Arm the OTA login with the supplied ed25519 key') } else { $p.Add('No key: open mode (empty root password accepted from the network)') }
    $p.Add('Create the boot entry "' + $Script:EntryName + '" and boot it once on the next restart')
    return , $p
}

# ---- messages and logging ----------------------------------------------------------------------------------

function Write-Log {
    param([string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { }
}
function Say {
    param([string]$Text)
    Write-Host $Text
    Write-Log $Text
    if ($Script:Opt.Remote -and $Script:Opt.MachineId) { Send-Remote $Text }
}
# Status file for an orchestrator: one JSON object, rewritten at the end of every run.
function Write-Status {
    param([string]$Result, [int]$Code, [string]$Message)
    $Script:Status.Result = $Result
    $Script:Status.Code = $Code
    $Script:Status.Message = $Message
    $Script:Status.Time = (Get-Date -Format 's')
    try { ($Script:Status | ConvertTo-Json) | Set-Content -LiteralPath $Script:StatusFile -Encoding UTF8 } catch { Write-Log ('status: ' + $_.Exception.Message) }
}
$Script:Step = ''
function Set-Step { param([string]$Name) $Script:Step = $Name; $Script:Status.Step = $Name }

# Step, error id (language independent), message and failing statement of an error record.
function Format-FailureDetail {
    param($ErrorRecord)
    return ('step "' + $Script:Step + '": ' + $ErrorRecord.Exception.Message + ' [' + $ErrorRecord.FullyQualifiedErrorId + '] at: ' + ("" + $ErrorRecord.InvocationInfo.Line).Trim())
}

function Show-Plan {
    param([hashtable]$Ctx)
    Say 'Plan:'
    foreach ($l in (Build-Plan $Ctx)) { Say ('  - ' + $l) }
}
function Stop-Script {
    param([string]$Text, [int]$Code = 1)
    Say ('Stopped: ' + $Text)
    $r = 'stopped'
    if ($Code -eq 0) { $r = 'cancelled' }
    Write-Status $r $Code $Text
    if ($Script:Opt.Remote) { throw ('UNITOTEM_EXIT:' + $Code) }
    exit $Code
}

# ---- system wrappers (replaced by mocks in the tests) ------------------------------------------------------

function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
    $code = $LASTEXITCODE
    Write-Log ('> ' + $Exe + ' ' + ($Arguments -join ' ') + ' => ' + $code)
    foreach ($o in $out) { Write-Log ('  ' + $o) }
    if ($code -ne 0) { throw ($Exe + ' failed (' + $code + '): ' + ($out -join ' ')) }
    return , $out
}
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# 1 = UEFI (winload.efi), 0 = legacy BIOS (winload.exe); locale independent.
function Get-FirmwareKind {
    $cur = (Invoke-Native 'bcdedit.exe' @('/enum', '{current}')) -join "`n"
    if ($cur -match 'winload\.efi') { return 'uefi' }
    if ($cur -match 'winload\.exe') { return 'bios' }
    return 'unknown'
}
function Get-SecureBootState {
    try { if (Confirm-SecureBootUEFI) { return 'on' } else { return 'off' } } catch { return 'unknown' }
}
# ConversionStatus of a volume: 0 decrypted, 1 encrypted, 2/4 encrypting, 3/5 decrypting; $null: no BitLocker.
function Get-BitLockerStatus {
    param([string]$Letter)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    # No BitLocker namespace (some editions, Safe Mode) means no BitLocker: $null, never an error.
    try {
        $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='" + $Letter + ":'") -ErrorAction Stop
        if ($null -eq $v) { return $null }
        $r = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    } catch { Write-Log ('BitLocker query: ' + $_.Exception.Message); return $null }
    if ($r.ReturnValue -ne 0) { return $null }
    return [int]$r.ConversionStatus
}
# Percent encrypted (0-100) of a volume, $null when unknown.
function Get-BitLockerPercent {
    param([string]$Letter)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    # No BitLocker namespace (some editions, Safe Mode) means no BitLocker: $null, never an error.
    try {
        $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='" + $Letter + ":'") -ErrorAction Stop
        if ($null -eq $v) { return $null }
        $r = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    } catch { Write-Log ('BitLocker query: ' + $_.Exception.Message); return $null }
    if ($r.ReturnValue -ne 0) { return $null }
    return [int]$r.EncryptionPercentage
}
# True when the volume needs decrypting (status other than "fully decrypted").
function Test-NeedsDecrypt {
    param($Status)
    return ($null -ne $Status -and [int]$Status -ne 0)
}
# Decrypts a volume and waits until "Fully Decrypted" or the timeout. Recovery keys are never read or printed.
# Safe to run again after an interruption: decryption resumes. Returns $true when done.
function Disable-Volume {
    param([string]$Letter, [int]$TimeoutSeconds)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    $st = Get-BitLockerStatus $Letter
    if (-not (Test-NeedsDecrypt $st)) { return $true }
    Say ('Decrypting ' + $Letter + ': (' + (Get-BitLockerPercent $Letter) + '% encrypted)')
    if ($st -ne 3) {
        try { Invoke-Native 'manage-bde.exe' @('-off', ($Letter + ':')) | Out-Null }
        catch {
            Say 'manage-bde unavailable; using Disable-BitLocker'
            Disable-BitLocker -MountPoint ($Letter + ':') | Out-Null
        }
    }
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastPrint = -1
    while ((Get-Date) -lt $end) {
        $st = Get-BitLockerStatus $Letter
        if (-not (Test-NeedsDecrypt $st)) { Say ($Letter + ': decrypted'); return $true }
        $pct = Get-BitLockerPercent $Letter
        if ($null -ne $pct -and ($lastPrint -lt 0 -or $lastPrint - $pct -ge 5)) { Say ('  ' + $pct + '% still encrypted'); $lastPrint = $pct }
        Start-Sleep -Seconds 5
    }
    return $false
}

# ---- main --------------------------------------------------------------------------------------------------

function Read-Word {
    param([string]$Prompt, [string]$Word)
    if ($Script:Opt.Unattended) { throw 'internal error: prompt in unattended mode' }
    $a = Read-Host $Prompt
    return ($a -ceq $Word)
}

function Get-Payload {
    param([string]$Dir, [string]$Mode)
    $sums = Read-Sums (Get-Content -LiteralPath (Join-Path $Dir 'SHA256SUMS'))
    $need = @('vmlinuz', 'initrd.img')
    if ($Mode -eq 'bios') { $need += @('g2.img', 'grub-bios.cfg.template') } else { $need += @('grub.cfg.template') + $Script:ChainFiles }
    foreach ($n in $need) {
        if (-not $sums.ContainsKey($n)) { throw ('missing in SHA256SUMS: ' + $n) }
        $f = Join-Path $Dir $n
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw ('missing file: ' + $n) }
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $sums[$n]) { throw ('checksum mismatch: ' + $n) }
    }
    return $sums
}

# Partition of a drive letter through the classic CIM classes (Win32_LogicalDiskToPartition), which do not depend on
# the Storage module's drive-letter index. Returns @{ DiskIndex; Offset; Size; Index } or $null.
function Get-LetterPartitionInfo {
    param([string]$Letter)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'")
    if ($null -eq $ld) { return $null }
    $dp = @(Get-CimAssociatedInstance -InputObject $ld -ResultClassName Win32_DiskPartition)
    if ($dp.Count -ne 1) { return $null }
    return @{ DiskIndex = [int]$dp[0].DiskIndex; Offset = [long]$dp[0].StartingOffset; Size = [long]$dp[0].Size; Index = [int]$dp[0].Index }
}

# The Storage partition that starts at Offset (partitions never share a start); $null when none.
function Select-PartitionByOffset {
    param($Partitions, [long]$Offset)
    foreach ($p in @($Partitions)) { if ([long]$p.Offset -eq $Offset) { return $p } }
    return $null
}

# Disk and partition objects from Win32_DiskDrive / Win32_DiskPartition, shaped like the Storage ones (Number,
# FriendlyName, Size, PartitionStyle, SerialNumber, UniqueId, BusType; PartitionNumber, Offset, Size, IsBoot, Type).
function ConvertFrom-CimDisk {
    param($DiskDrive, $Partitions)
    $style = 'RAW'
    foreach ($p in @($Partitions)) { if ([string]$p.Type -like 'GPT*') { $style = 'GPT'; break } elseif ([string]$p.Type) { $style = 'MBR' } }
    return [pscustomobject]@{ Number = [int]$DiskDrive.Index; FriendlyName = [string]$DiskDrive.Model; Size = [long]$DiskDrive.Size; PartitionStyle = $style; SerialNumber = ("" + $DiskDrive.SerialNumber).Trim(); UniqueId = [string]$DiskDrive.PNPDeviceID; BusType = [string]$DiskDrive.InterfaceType }
}
function ConvertFrom-CimPartition {
    param($Part)
    return [pscustomobject]@{ PartitionNumber = [int]$Part.Index + 1; Offset = [long]$Part.StartingOffset; Size = [long]$Part.Size; IsBoot = [bool]$Part.BootPartition; IsActive = [bool]$Part.BootPartition; DriveLetter = ''; Type = [string]$Part.Type; DiskNumber = [int]$Part.DiskIndex }
}
function Get-CimPartitions {
    param([int]$DiskIndex)
    return @(Get-CimInstance -ClassName Win32_DiskPartition -Filter ('DiskIndex=' + $DiskIndex))
}

# All disks: the Storage module, else the classic CIM classes (when the Storage provider sees nothing, e.g. Safe Mode).
function Get-DisksSafe {
    try { $d = @(Get-Disk); if ($d.Count -gt 0) { return $d } } catch { Write-Log ('Get-Disk: ' + $_.Exception.Message) }
    $out = @()
    foreach ($dd in (Get-CimInstance -ClassName Win32_DiskDrive)) { $out += ConvertFrom-CimDisk $dd (Get-CimPartitions ([int]$dd.Index)) }
    return $out
}
function Get-PartitionsSafe {
    param([int]$DiskNumber)
    try { $p = @(Get-Partition -DiskNumber $DiskNumber); if ($p.Count -gt 0) { return $p } } catch { Write-Log ('Get-Partition: ' + $_.Exception.Message) }
    return @(Get-CimPartitions $DiskNumber | ForEach-Object { ConvertFrom-CimPartition $_ })
}

# System drive -> disk and partition. No -DriveLetter filter on Get-Partition: it finds nothing when the Storage
# provider has no letter for the partition (seen in Safe Mode). Falls back to the CIM classes when Storage is blind.
function Get-SystemDisk {
    Set-Step 'find the system disk'
    $letter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
    if (-not (Test-FullMatch $letter $Script:Re.Letter)) { throw 'system drive not recognised' }
    $info = Get-LetterPartitionInfo $letter
    $part = $null
    $disk = $null
    if ($null -ne $info) {
        $disk = @(Get-DisksSafe | Where-Object { [int]$_.Number -eq $info.DiskIndex }) | Select-Object -First 1
        $part = Select-PartitionByOffset (Get-PartitionsSafe $info.DiskIndex) $info.Offset
    }
    if ($null -eq $part -or $null -eq $disk) {
        # Last resort: the partition flagged as boot partition by the Storage module.
        $part = @(Get-Partition | Where-Object { $_.IsBoot }) | Select-Object -First 1
        if ($null -eq $part) { throw ('no partition found for ' + $letter + ':') }
        $disk = Get-Disk -Number $part.DiskNumber
    }
    if (-not (Test-FullMatch ([string]$disk.Number) $Script:Re.Number)) { throw 'invalid disk number' }
    return @{ Letter = $letter; Part = $part; Disk = $disk }
}

# Volume facts of a letter from Win32_LogicalDisk: @{ FileSystem; SizeRemaining; Size; Label } or $null.
# normal | safe. SAFEBOOT_OPTION is set by Windows in Safe Mode; SystemInformation.BootMode is the .NET view of it.
function Get-BootMode {
    if ($env:SAFEBOOT_OPTION) { return 'safe' }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        if ([string][Windows.Forms.SystemInformation]::BootMode -ne 'Normal') { return 'safe' }
    } catch { }
    return 'normal'
}

# "disk:offset" -> drive letter, from Win32_LogicalDiskToPartition (the Storage module shows no letters in Safe Mode).
function Get-CimLetterMap {
    $map = @{}
    try {
        foreach ($ld in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
            foreach ($dp in @(Get-CimAssociatedInstance -InputObject $ld -ResultClassName Win32_DiskPartition)) {
                $map[([string]$dp.DiskIndex + ':' + [string][long]$dp.StartingOffset)] = ([string]$ld.DeviceID).Substring(0, 1)
            }
        }
    } catch { Write-Log ('letter map: ' + $_.Exception.Message) }
    return $map
}
function Get-PartLetter {
    param([int]$DiskNumber, $Part, $Map)
    $k = [string]$DiskNumber + ':' + [string][long]$Part.Offset
    if ($Map.ContainsKey($k)) { return [string]$Map[$k] }
    if ($Part.DriveLetter) { return [string]$Part.DriveLetter }
    return ''
}

# Primary entries of the MBR of a physical disk: @{ Type; Active; Offset }. Empty when it cannot be read.
function Get-MbrEntries {
    param([int]$DiskIndex)
    $b = New-Object byte[] 512
    try {
        $fs = New-Object IO.FileStream(('\\.\PHYSICALDRIVE' + $DiskIndex), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { [void]$fs.Read($b, 0, 512) } finally { $fs.Dispose() }
    } catch { Write-Log ('MBR read: ' + $_.Exception.Message); return @() }
    if ($b[510] -ne 0x55 -or $b[511] -ne 0xAA) { return @() }
    $out = @()
    for ($i = 0; $i -lt 4; $i++) {
        $o = 446 + 16 * $i
        if ($b[$o + 4] -ne 0) { $out += @{ Type = [int]$b[$o + 4]; Active = ($b[$o] -eq 0x80); Offset = [long][BitConverter]::ToUInt32($b, $o + 8) * 512 } }
    }
    return $out
}

# Where the boot files of a legacy-BIOS install go. In order: the active partition (when it has the room), C: (NTFS,
# not encrypted), a new FAT32 partition (needs the Storage services, which Safe Mode does not run). Pure.
#   Facts: ActiveLetter, ActiveFs, ActiveFree, CFs, CFree, CEncrypted, BootMode, PartCount, HasOta
function Select-BiosWhere {
    param([hashtable]$F, [long]$Need)
    if ($F.ActiveLetter -and ($F.ActiveFs -in 'NTFS', 'FAT32') -and (Get-StorageChoice $F.ActiveFree $Need) -eq 'boot') {
        return @{ Where = 'boot'; Reason = 'the active partition has room' }
    }
    if ($F.CFs -eq 'NTFS' -and -not $F.CEncrypted -and (Get-StorageChoice $F.CFree $Need) -eq 'boot') {
        return @{ Where = 'cdrive'; Reason = 'the active partition is too small or has no drive letter; C: is NTFS, not encrypted, with room' }
    }
    if ($F.BootMode -ne 'normal') {
        return @{ Where = 'none'; Reason = 'Storage services are stopped in Safe Mode and no existing partition can hold the files: restart in normal mode' }
    }
    if ($F.PartCount -ge 4 -and -not $F.HasOta) {
        return @{ Where = 'none'; Reason = 'no existing partition can hold the files and the MBR disk has no free primary slot' }
    }
    return @{ Where = 'new'; Reason = 'no existing partition can hold the files; a new FAT32 partition is created' }
}

function Get-LetterVolume {
    param([string]$Letter)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'")
    if ($null -eq $ld) { return $null }
    return @{ FileSystem = [string]$ld.FileSystem; SizeRemaining = [long]$ld.FreeSpace; Size = [long]$ld.Size; Label = [string]$ld.VolumeName }
}

function Get-SupportedSize {
    param($Sd)
    return (Get-PartitionSupportedSize -DiskNumber $Sd.Disk.Number -PartitionNumber $Sd.Part.PartitionNumber)
}

function Show-Disk {
    param($Disk)
    Say ('Disk {0}: {1}, {2} GB, {3}, serial {4}' -f $Disk.Number, $Disk.FriendlyName.Trim(), [math]::Round($Disk.Size / 1GB, 1), $Disk.PartitionStyle, ("" + $Disk.SerialNumber).Trim())
    foreach ($p in (Get-PartitionsSafe $Disk.Number | Sort-Object PartitionNumber)) {
        $l = ''
        if ($p.DriveLetter) { $l = [string]$p.DriveLetter + ':' }
        Say ('  #{0} {1,-5} {2,9} MB  {3}' -f $p.PartitionNumber, $l, [math]::Round($p.Size / 1MB), $p.Type)
    }
}

function Find-OtaPartition {
    param([int]$DiskNumber)
    return @(Get-PartitionsSafe $DiskNumber | Where-Object {
            $v = $null
            try { $v = $_ | Get-Volume -ErrorAction SilentlyContinue } catch { }
            $null -ne $v -and $v.FileSystemLabel -ceq $Script:Label
        })
}

function Mount-Esp {
    param([string]$Letter)
    Invoke-Native 'mountvol.exe' @(($Letter + ':'), '/S') | Out-Null
}
function Dismount-Esp {
    param([string]$Letter)
    try { Invoke-Native 'mountvol.exe' @(($Letter + ':'), '/D') | Out-Null } catch { Write-Log ('dismount: ' + $_.Exception.Message) }
}
function Get-UsedLetters { return @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() }) }

function Get-FreeBytes { param([string]$Letter) return (New-Object IO.DriveInfo ($Letter + ':')).AvailableFreeSpace }

# Sum of the file sizes under a folder (0 when absent).
function Get-FolderBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Measure-Object -Property Length -Sum
    if ($null -eq $m.Sum) { return 0L }
    return [long]$m.Sum
}

function Get-TokenFromFile {
    param([string]$File)
    if (-not $File) { return $null }
    $key = Get-KeyLine (Get-Content -LiteralPath $File)
    if ($null -eq $key) { Stop-Script 'the key file must hold one ssh-ed25519 public key line' $Script:Exit.Usage }
    return (ConvertTo-AuthKeyToken $key)
}

function Test-HashOf {
    param([string]$File, [string]$Expected)
    $h = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $Expected) { throw ('copy verification failed: ' + (Split-Path -Leaf $File)) }
}

# Shrinks C: and creates the FAT32 partition (reused when it already exists); returns its drive letter.
# BitLocker is turned off on the new partition only (Windows 11 encrypts it by itself).
function New-OtaPartition {
    param($Sd, [long]$PartBytes)
    Set-Step 'create the boot-files partition'
    $existing = @(Find-OtaPartition $Sd.Disk.Number)
    if ($existing.Count -eq 0) {
        Set-Step 'shrink C:'
        Resize-Partition -DiskNumber $Sd.Disk.Number -PartitionNumber $Sd.Part.PartitionNumber -Size ($Sd.Part.Size - $PartBytes)
        Set-Step 'create the FAT32 partition'
        $np = New-Partition -DiskNumber $Sd.Disk.Number -Size $PartBytes
    } else {
        $np = $existing[0]
    }
    $num = [int]$np.PartitionNumber
    $pl = ''
    if ($np.DriveLetter) { $pl = [string]$np.DriveLetter } else {
        $pl = Get-FreeLetter (Get-UsedLetters)
        Add-PartitionAccessPath -DiskNumber $Sd.Disk.Number -PartitionNumber $num -AccessPath ($pl + ':')
    }
    if (-not (Test-FullMatch $pl $Script:Re.Letter)) { throw 'new partition has no drive letter' }
    $vol = Get-LetterVolume $pl
    if ($null -eq $vol -or $vol.FileSystem -ne 'FAT32' -or $vol.Label -cne $Script:Label) {
        Set-Step 'format the FAT32 partition'
        Format-Volume -Partition (Get-Partition -DiskNumber $Sd.Disk.Number -PartitionNumber $num) -FileSystem FAT32 -NewFileSystemLabel $Script:Label -Confirm:$false | Out-Null
    }
    Set-Step 'turn BitLocker off on the new partition'
    if (-not (Disable-Volume $pl 600)) { throw 'the new partition stays encrypted' }
    if ((Get-LetterVolume $pl).FileSystem -ne 'FAT32') { throw 'the new partition is not readable FAT32' }
    return $pl
}

function Save-State {
    param([hashtable]$State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $Script:StateFile -Encoding ASCII
}

function Show-Result {
    param($Guid, $Token)
    $Script:Status.BootEntry = $Guid
    Say ('Ready. One-shot boot entry ' + $Guid + ' set for the next restart.')
    if ($Token) { Say 'OTA login: the supplied key.' } else { Say 'OTA login: open mode.' }
    Say 'After the restart the screen shows the address. Then run on the host: deploy/remote-deploy.sh recover ADDRESS --parts DIR'
    Say 'To cancel before the install: run this script with -Undo.'
    Write-Status 'prepared' 0 'boot entry created'
    if ($Script:Opt.Remote) { Invoke-StatusFlushFinal }
    $go = $false
    if ($Script:Opt.Unattended) { $go = [bool]$Script:Opt.Reboot } else { $go = Read-Word 'Type RESTART to restart now' 'RESTART' }
    if ($go) { Invoke-Native 'shutdown.exe' @('/r', '/t', '10', '/c', 'UniTotem OTA') | Out-Null }
}

function Confirm-Erase {
    param($Disk)
    $w = Get-ConfirmWord $env:COMPUTERNAME $Disk.Number ("" + $Disk.SerialNumber).Trim()
    $Script:Status.ExpectedToken = $w
    $Script:Status.DiskNumber = $Disk.Number
    $Script:Status.DiskSerial = ("" + $Disk.SerialNumber).Trim()
    $Script:Status.DiskModel = $Disk.FriendlyName.Trim()
    if ($Script:Opt.Unattended) {
        if ($Disk.Number -ne $Script:Opt.Disk) { Stop-Script ('the system disk is disk ' + $Disk.Number + ', not ' + $Script:Opt.Disk) $Script:Exit.NotConfirmed }
        if ($Script:Opt.WhatIf) { return }
        if (-not ($Script:Opt.ConfirmToken -ceq $w)) { Stop-Script 'the confirmation token does not match the disk' $Script:Exit.NotConfirmed }
        return
    }
    if ($Script:Opt.WhatIf) { return }
    if (-not (Read-Word ('Type ' + $w + ' to confirm that disk ' + $Disk.Number + ' will be erased') $w)) { Stop-Script 'not confirmed' 0 }
}

function Invoke-Undo {
    if (-not (Test-Path -LiteralPath $Script:StateFile)) { Stop-Script 'nothing to undo (no state file)' 0 }
    $st = Get-Content -LiteralPath $Script:StateFile -Raw | ConvertFrom-Json
    if (-not (Test-FullMatch ([string]$st.Guid) $Script:Re.Guid)) { Stop-Script 'state file invalid' }
    if (-not (Test-FullMatch ([string]$st.DiskNumber) $Script:Re.Number)) { Stop-Script 'state file invalid' }
    $mode = 'uefi'
    if ([string]$st.Mode -ceq 'bios') { $mode = 'bios' }
    Show-Plan @{ Undo = $true; Mode = $mode }
    if ($Script:Opt.WhatIf) { Say 'Dry run: nothing changed.'; Write-Status 'dry-run' 0 'plan printed'; return }
    if (-not $Script:Opt.Unattended -and -not (Read-Word 'Type UNDO to continue' 'UNDO')) { Stop-Script 'not confirmed' 0 }
    $g = [string]$st.Guid
    if ($mode -eq 'bios') {
        $steps = @(@('/displayorder', $g, '/remove'), @('/deletevalue', '{bootmgr}', 'bootsequence'), @('/delete', $g, '/f'))
    } else {
        $steps = @(@('/set', '{fwbootmgr}', 'displayorder', $g, '/remove'), @('/deletevalue', '{fwbootmgr}', 'bootsequence'), @('/delete', $g, '/f'))
    }
    foreach ($a in $steps) {
        try { Invoke-Native 'bcdedit.exe' $a | Out-Null } catch { Write-Log ('undo step: ' + $_.Exception.Message) }
    }
    # Boot files: ESP folder (UEFI) or the boot partition folder and loader (BIOS).
    $letter = Get-FreeLetter (Get-UsedLetters)
    $sysLetter = [string]$st.SystemLetter
    if ($mode -eq 'bios') {
        if (-not (Test-FullMatch $sysLetter $Script:Re.Letter)) { Stop-Script 'state file invalid' }
        foreach ($kl in @($sysLetter, [string]$st.KernelLetter)) {
            if (-not (Test-FullMatch $kl $Script:Re.Letter)) { continue }
            $dir = $kl + ':\' + $Script:BiosDir
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        $img = $sysLetter + ':\' + $Script:BiosImage
        if (Test-Path -LiteralPath $img) { Remove-Item -LiteralPath $img -Force }
    } else {
        Mount-Esp $letter
        try {
            $dir = $letter + ':\' + $Script:EspDir
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        } finally { Dismount-Esp $letter }
    }
    $removed = $false
    foreach ($p in (Find-OtaPartition ([int]$st.DiskNumber))) { Remove-Partition -InputObject $p -Confirm:$false; $removed = $true }
    if ($removed) {
        try {
            $usd = Get-SystemDisk
            Resize-Partition -DiskNumber $usd.Disk.Number -PartitionNumber $usd.Part.PartitionNumber -Size (Get-SupportedSize $usd).SizeMax
        } catch { Say 'C: not extended; extend it in Disk Management.' }
    }
    Remove-Item -LiteralPath $Script:StateFile -Force
    Say 'Undone.'
    Write-Status 'undone' 0 'boot entry and files removed'
}

# UEFI: signed shim/GRUB chain on the ESP; kernel and initrd on the ESP when they fit, else on a new FAT32 partition.
function Invoke-Install {
    $PayloadDir = $Script:Opt.PayloadDir
    if (-not $PayloadDir) { $PayloadDir = Join-Path $Script:Here 'payload' }
    try { $sums = Get-Payload $PayloadDir 'uefi' } catch { Stop-Script ('payload: ' + $_.Exception.Message) $Script:Exit.Payload }
    $kiBytes = 0L
    foreach ($n in @('vmlinuz', 'initrd.img')) { $kiBytes += (Get-Item -LiteralPath (Join-Path $PayloadDir $n)).Length }
    $chainBytes = 0L
    foreach ($n in $Script:ChainFiles) { $chainBytes += (Get-Item -LiteralPath (Join-Path $PayloadDir $n)).Length }
    $token = Get-TokenFromFile $Script:Opt.AuthorizedKey

    $sd = Get-SystemDisk
    if ([string]$sd.Disk.PartitionStyle -ne 'GPT') { Stop-Script 'the system disk is not GPT' $Script:Exit.Unsupported }
    # Free space of the ESP, counting what an earlier run of this script already put there.
    $espLetter = Get-FreeLetter (Get-UsedLetters)
    Mount-Esp $espLetter
    try {
        $free = Get-FreeBytes $espLetter
        $free += Get-FolderBytes ($espLetter + ':\' + $Script:EspDir)
    } finally { Dismount-Esp $espLetter }
    $where = Get-StorageChoice $free ($kiBytes + $chainBytes + 1MB)
    $Script:Status.Mode = 'uefi'; $Script:Status.Where = $where
    if ($where -eq 'new' -and ($free -lt ($chainBytes * 2 + $Script:EspMarginBytes))) { Stop-Script 'the EFI system partition has too little free space for the boot loader' $Script:Exit.Unsupported }
    $partBytes = Get-PartitionBytes $kiBytes
    if ($where -eq 'new' -and @(Find-OtaPartition $sd.Disk.Number).Count -eq 0) {
        $sup = Get-SupportedSize $sd
        if (-not (Test-ShrinkFeasible $sd.Part.Size $sup.SizeMin $partBytes)) { Stop-Script 'C: cannot shrink enough; free disk space first' $Script:Exit.Unsupported }
    }
    $ctx = @{ Undo = $false; Mode = 'uefi'; Where = $where; NeededBytes = ($kiBytes + $chainBytes); PartBytes = $partBytes; Token = $token }

    Say ('Secure Boot: ' + (Get-SecureBootState))
    Say ('EFI system partition free: {0} MiB' -f [math]::Round($free / 1MB))
    Show-Disk $sd.Disk
    Say 'UniTotem will ERASE this whole disk when the host starts the install. Windows will be gone.'
    Show-Plan $ctx
    Confirm-Erase $sd.Disk
    if ($Script:Opt.WhatIf) { Say 'Dry run: nothing changed.'; Write-Status 'dry-run' 0 'plan printed'; return }

    $guid = $null
    $partLetter = $null
    if ($where -eq 'new') { $partLetter = New-OtaPartition $sd $partBytes; $Script:Status.Partition = ($partLetter + ': ' + $Script:Label) } else { $Script:Status.Partition = 'EFI system partition' }
    Mount-Esp $espLetter
    try {
        $dst = $espLetter + ':\' + $Script:EspDir
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        foreach ($n in $Script:ChainFiles) { Copy-Item -LiteralPath (Join-Path $PayloadDir $n) -Destination (Join-Path $dst $n) -Force }
        if ($where -eq 'boot') { $kdir = $dst; $gdir = '/' + ($Script:EspDir -replace '\\', '/') } else { $kdir = $partLetter + ':\'; $gdir = '' }
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'vmlinuz') -Destination (Join-Path $kdir 'unitotem-vmlinuz') -Force
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'initrd.img') -Destination (Join-Path $kdir 'unitotem-initrd.img') -Force
        $tpl = Get-Content -LiteralPath (Join-Path $PayloadDir 'grub.cfg.template') -Raw
        [IO.File]::WriteAllText((Join-Path $dst 'grub.cfg'), (New-GrubCfg $tpl $token $gdir).Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        foreach ($n in $Script:ChainFiles) { Test-HashOf (Join-Path $dst $n) $sums[$n] }
        Test-HashOf (Join-Path $kdir 'unitotem-vmlinuz') $sums['vmlinuz']
        Test-HashOf (Join-Path $kdir 'unitotem-initrd.img') $sums['initrd.img']

        $o = Invoke-Native 'bcdedit.exe' @('/copy', '{bootmgr}', '/d', $Script:EntryName)
        $guid = Get-BcdGuid $o
        if ($null -eq $guid) { throw 'bcdedit returned no entry id' }
        Save-State @{ Mode = 'uefi'; Guid = $guid; DiskNumber = $sd.Disk.Number; Where = $where }
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'device', ('partition=' + $espLetter + ':')) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'path', ('\' + $Script:EspDir + '\shimx64.efi')) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', '{fwbootmgr}', 'displayorder', $guid, '/addfirst') | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', '{fwbootmgr}', 'bootsequence', $guid) | Out-Null
    } finally { Dismount-Esp $espLetter }
    Show-Result $guid $token
}

# Legacy BIOS: the Windows boot manager starts GRUB 2 (lnxboot.img + core.img) as a boot-sector entry; GRUB reads
# kernel and initrd from NTFS or FAT32. They go on the active (boot) partition when they fit, else on C: (NTFS, not
# encrypted: only file copies and bcdedit, no Storage module), else on a new FAT32 partition.
function Invoke-InstallBios {
    $PayloadDir = $Script:Opt.PayloadDir
    if (-not $PayloadDir) { $PayloadDir = Join-Path $Script:Here 'payload' }
    try { $sums = Get-Payload $PayloadDir 'bios' } catch { Stop-Script ('payload: ' + $_.Exception.Message) $Script:Exit.Payload }
    $kiBytes = 0L
    foreach ($n in @('vmlinuz', 'initrd.img')) { $kiBytes += (Get-Item -LiteralPath (Join-Path $PayloadDir $n)).Length }
    $token = Get-TokenFromFile $Script:Opt.AuthorizedKey

    $sd = Get-SystemDisk
    if ([string]$sd.Disk.PartitionStyle -ne 'MBR') { Stop-Script 'the system disk is not MBR' $Script:Exit.Unsupported }
    Set-Step 'choose the place for the boot files'
    $map = Get-CimLetterMap
    $parts = @(Get-PartitionsSafe $sd.Disk.Number)
    $active = @($parts | Where-Object { $_.IsActive })
    if ($active.Count -ne 1) { Stop-Script 'no single active (boot) partition on the system disk' $Script:Exit.Unsupported }
    $ap = $active[0]
    $actLetter = Get-PartLetter $sd.Disk.Number $ap $map
    $actFs = ''; $actFree = 0L
    if ($actLetter) { $v = Get-LetterVolume $actLetter; if ($v) { $actFs = $v.FileSystem; $actFree = $v.SizeRemaining + (Get-FolderBytes ($actLetter + ':\' + $Script:BiosDir)) } }
    $cv = Get-LetterVolume $sd.Letter
    $cFree = 0L; $cFs = ''
    if ($cv) { $cFs = $cv.FileSystem; $cFree = $cv.SizeRemaining + (Get-FolderBytes ($sd.Letter + ':\' + $Script:BiosDir)) }
    $facts = @{ ActiveLetter = $actLetter; ActiveFs = $actFs; ActiveFree = $actFree; CFs = $cFs; CFree = $cFree; CEncrypted = (Test-NeedsDecrypt (Get-BitLockerStatus $sd.Letter)); BootMode = (Get-BootMode); PartCount = $parts.Count; HasOta = (@(Find-OtaPartition $sd.Disk.Number).Count -gt 0) }
    $choice = Select-BiosWhere $facts ($kiBytes + 1MB)
    $where = $choice.Where
    $Script:Status.Mode = 'bios'; $Script:Status.Where = $where
    if ($where -eq 'none') { Stop-Script $choice.Reason $Script:Exit.Unsupported }
    $partBytes = Get-PartitionBytes $kiBytes
    if ($where -eq 'new' -and -not $facts.HasOta) {
        $sup = Get-SupportedSize $sd
        if (-not (Test-ShrinkFeasible $sd.Part.Size $sup.SizeMin $partBytes)) { Stop-Script 'C: cannot shrink enough; free disk space first' $Script:Exit.Unsupported }
    }
    $ctx = @{ Undo = $false; Mode = 'bios'; Where = $where; NeededBytes = $kiBytes; PartBytes = $partBytes; Token = $token }
    Say 'Secure Boot: not applicable (legacy BIOS)'
    Say ('Destination: ' + $where + ' (' + $choice.Reason + ')')
    Show-Disk $sd.Disk
    Say 'UniTotem will ERASE this whole disk when the host starts the install. Windows will be gone.'
    Show-Plan $ctx
    Confirm-Erase $sd.Disk
    if ($Script:Opt.WhatIf) { Say 'Dry run: nothing changed.'; Write-Status 'dry-run' 0 'plan printed'; return }

    # imgLetter holds the loader image (bootmgr must read it); kletter holds kernel and initrd.
    $assigned = $false
    $imgLetter = $actLetter
    if ($where -eq 'cdrive') {
        $imgLetter = $sd.Letter
    } elseif (-not $imgLetter) {
        $imgLetter = Get-FreeLetter (Get-UsedLetters)
        Add-PartitionAccessPath -DiskNumber $sd.Disk.Number -PartitionNumber $ap.PartitionNumber -AccessPath ($imgLetter + ':')
        $assigned = $true
    }
    if (-not (Test-FullMatch $imgLetter $Script:Re.Letter)) { throw 'boot partition has no drive letter' }
    $guid = $null
    try {
        Set-Step 'copy the boot files'
        if ($where -eq 'boot') {
            # The boot partition is left unencrypted by design; if it is not, GRUB cannot read it.
            if (-not (Disable-Volume $imgLetter ($Script:Opt.DecryptTimeoutMinutes * 60))) { Stop-Script ('decryption of the boot partition did not finish in ' + $Script:Opt.DecryptTimeoutMinutes + ' min; run this script again to continue') $Script:Exit.DecryptTimeout }
            $kletter = $imgLetter
        } elseif ($where -eq 'cdrive') {
            $kletter = $sd.Letter
        } else {
            $kletter = New-OtaPartition $sd $partBytes
        }
        $Script:Status.Partition = ($kletter + ':')
        $dir = $kletter + ':\' + $Script:BiosDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'vmlinuz') -Destination (Join-Path $dir 'recovery-vmlinuz') -Force
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'initrd.img') -Destination (Join-Path $dir 'recovery-initrd.img') -Force
        $tpl = Get-Content -LiteralPath (Join-Path $PayloadDir 'grub-bios.cfg.template') -Raw
        [IO.File]::WriteAllText((Join-Path $dir 'grub.cfg'), (New-GrubCfg $tpl $token).Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        $img = $imgLetter + ':\' + $Script:BiosImage
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'g2.img') -Destination $img -Force
        Test-HashOf (Join-Path $dir 'recovery-vmlinuz') $sums['vmlinuz']
        Test-HashOf (Join-Path $dir 'recovery-initrd.img') $sums['initrd.img']
        Test-HashOf $img $sums['g2.img']
        Set-Step 'create the boot entry'
        $o = Invoke-Native 'bcdedit.exe' @('/create', '/d', $Script:EntryName, '/application', 'bootsector')
        $guid = Get-BcdGuid $o
        if ($null -eq $guid) { throw 'bcdedit returned no entry id' }
        Save-State @{ Mode = 'bios'; Guid = $guid; DiskNumber = $sd.Disk.Number; SystemLetter = $imgLetter; KernelLetter = $kletter; Where = $where }
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'device', ('partition=' + $imgLetter + ':')) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'path', ('\' + $Script:BiosImage)) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/displayorder', $guid, '/addlast') | Out-Null
        Invoke-Native 'bcdedit.exe' @('/bootsequence', $guid) | Out-Null
    } finally {
        if ($assigned) { try { Remove-PartitionAccessPath -DiskNumber $sd.Disk.Number -PartitionNumber $ap.PartitionNumber -AccessPath ($imgLetter + ':') } catch { Write-Log ('letter: ' + $_.Exception.Message) } }
    }
    Show-Result $guid $token
}

# ---- remote mode (irm | iex): inventory, approval from the host, download, then the normal flow ------------

# Short sanitised text for the JSON sent to the server.
# Unicode text with control characters (C0, DEL, C1) removed; a cut ends with a marker, never silently.
function Get-Printable {
    param([string]$Text, [int]$Max = 200)
    $t = [regex]::Replace(("" + $Text), '[\x00-\x1F\x7F-\x9F]', '')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...[truncated ' + ($t.Length - $Max) + ']' }
    return $t
}

function Send-Json {
    param([string]$Path, $Body, [int]$TimeoutSec = 15)
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 6 -Compress))
    return (Invoke-RestMethod -Uri ($Script:Opt.Server + $Path) -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec)
}

# Seconds to wait after the Nth consecutive failure: 5, 10, 20, 30, 30, ...
function Get-Backoff {
    param([int]$Attempt)
    $v = 5 * [math]::Pow(2, [math]::Max(0, $Attempt - 1))
    if ($v -gt 30) { $v = 30 }
    return [int]$v
}

# Progress lines for the server: a bounded local queue, sent when the host answers, never blocking or fatal.
$Script:StatusQueue = New-Object System.Collections.Generic.Queue[object]
$Script:StatusFails = 0
$Script:StatusNext = [datetime]::MinValue
$Script:StatusDropped = 0
$Script:StatusQueueMax = 200

function Invoke-StatusFlush {
    param([switch]$Force)
    while ($Script:StatusQueue.Count -gt 0) {
        if (-not $Force -and (Get-Date) -lt $Script:StatusNext) { return }
        try { Send-Json '/status' $Script:StatusQueue.Peek() 5 | Out-Null } catch {
            $Script:StatusFails++
            $wait = Get-Backoff $Script:StatusFails
            $Script:StatusNext = (Get-Date).AddSeconds($wait)
            Write-Log ('status post failed (' + $Script:StatusQueue.Count + ' queued, retry in ' + $wait + ' s): ' + $_.Exception.Message)
            return
        }
        [void]$Script:StatusQueue.Dequeue()
        $Script:StatusFails = 0
    }
}

function Send-Remote {
    param([string]$Text)
    $level = 'info'
    if ($Text -like 'Stopped:*' -or $Text -like 'Failed:*') { $level = 'error' } elseif ($Text -like 'Ready*') { $level = 'ok' }
    try {
        $Script:StatusQueue.Enqueue(@{ machine = $Script:Opt.MachineId; level = $level; text = (Get-Printable $Text 4000) })
        while ($Script:StatusQueue.Count -gt $Script:StatusQueueMax) { [void]$Script:StatusQueue.Dequeue(); $Script:StatusDropped++; Write-Log 'status queue full: oldest line dropped' }
        Invoke-StatusFlush
    } catch { Write-Log ('status: ' + $_.Exception.Message) }
}

# Last attempts before the restart; the local steps never depend on the host.
function Invoke-StatusFlushFinal {
    for ($i = 0; $i -lt 3 -and $Script:StatusQueue.Count -gt 0; $i++) { Invoke-StatusFlush -Force; if ($Script:StatusQueue.Count -gt 0) { Start-Sleep -Seconds 2 } }
}

function Get-MachineId {
    $g = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    if (-not (Test-FullMatch $g $Script:Re.MachineId)) { throw 'machine id not recognised' }
    return $g
}

# Free MiB of the unencrypted boot partition (UEFI: ESP, BIOS: active partition); $null when unknown.
function Get-BootFreeMb {
    param([string]$Firmware, $Sd)
    try {
        if ($Firmware -eq 'uefi') {
            $l = Get-FreeLetter (Get-UsedLetters)
            Mount-Esp $l
            try { return [int]([math]::Floor((Get-FreeBytes $l) / 1MB)) } finally { Dismount-Esp $l }
        }
        $ap = @(Get-PartitionsSafe $Sd.Disk.Number | Where-Object { $_.IsActive })
        $l = ''
        if ($ap.Count -eq 1) { $l = Get-PartLetter $Sd.Disk.Number $ap[0] (Get-CimLetterMap) }
        if ($l) { return [int]([math]::Floor((Get-LetterVolume $l).SizeRemaining / 1MB)) }
        # No letter (System Reserved): the system volume through Win32_Volume.
        $sv = @(Get-CimInstance -ClassName Win32_Volume -Filter 'SystemVolume=TRUE') | Select-Object -First 1
        if ($sv) { return [int]([math]::Floor([long]$sv.FreeSpace / 1MB)) }
    } catch { Write-Log ('boot free space: ' + $_.Exception.Message) }
    return $null
}

function Get-CimField {
    param([scriptblock]$Block)
    try { $v = & $Block; if ($null -ne $v -and "$v".Trim() -ne '') { return (Get-Printable ("" + $v).Trim() 120) } } catch { Write-Log ('field: ' + $_.Exception.Message) }
    return 'unknown'
}
function Get-MachineModel { return (Get-CimField { $c = Get-CimInstance Win32_ComputerSystem; ($c.Manufacturer + ' ' + $c.Model) }) }
function Get-CpuInfo {
    return (Get-CimField {
        $p = @(Get-CimInstance Win32_Processor)
        $cores = 0; $threads = 0
        foreach ($x in $p) { $cores += [int]$x.NumberOfCores; $threads += [int]$x.NumberOfLogicalProcessors }
        ($p[0].Name.Trim() + ', ' + $cores + ' cores, ' + $threads + ' threads')
    })
}
function Get-RamInfo {
    return (Get-CimField {
        $gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $mods = 0; try { $mods = @(Get-CimInstance Win32_PhysicalMemory).Count } catch { }
        if ($mods -gt 0) { ('' + $gb + ' GB, ' + $mods + ' modules') } else { ('' + $gb + ' GB') }
    })
}

# Plan hint sent with the inventory: where the boot files would go, and what Safe Mode changes.
function Get-PlanHint {
    param([string]$Firmware, $Sd, [string]$BootMode)
    $notes = @()
    if ($BootMode -eq 'safe') { $notes += 'Safe Mode: the Storage services are stopped; shrinking C: and creating partitions are unavailable. Copying files and bcdedit work.' }
    $map = Get-CimLetterMap
    $kiEstimate = [long]$Script:Opt.PayloadBytes
    if ($Firmware -eq 'bios') {
        $parts = @(Get-PartitionsSafe $Sd.Disk.Number)
        $act = @($parts | Where-Object { $_.IsActive }) | Select-Object -First 1
        $al = ''; $afs = ''; $afree = 0L
        if ($act) {
            $al = Get-PartLetter $Sd.Disk.Number $act $map
            if ($al) { $v = Get-LetterVolume $al; if ($v) { $afs = $v.FileSystem; $afree = $v.SizeRemaining } }
        }
        $cv = Get-LetterVolume $Sd.Letter
        $enc = Test-NeedsDecrypt (Get-BitLockerStatus $Sd.Letter)
        $f = @{ ActiveLetter = $al; ActiveFs = $afs; ActiveFree = $afree; CFs = $(if ($cv) { $cv.FileSystem } else { '' }); CFree = $(if ($cv) { $cv.SizeRemaining } else { 0L }); CEncrypted = $enc; BootMode = $BootMode; PartCount = $parts.Count; HasOta = (@(Find-OtaPartition $Sd.Disk.Number).Count -gt 0) }
        $r = Select-BiosWhere $f $kiEstimate
    } else {
        $free = Get-BootFreeMb $Firmware $Sd
        if ($null -ne $free -and (Get-StorageChoice ([long]$free * 1MB) $kiEstimate) -eq 'boot') { $r = @{ Where = 'boot'; Reason = 'the EFI system partition has room' } }
        elseif ($BootMode -ne 'normal') { $r = @{ Where = 'none'; Reason = 'the EFI system partition is too small and Storage services are stopped in Safe Mode: restart in normal mode' } }
        else { $r = @{ Where = 'new'; Reason = 'the EFI system partition is too small; a new FAT32 partition is created' } }
    }
    return @{ plan = @{ where = $r.Where; reason = (Get-Printable $r.Reason 200) }; notes = $notes }
}

# Read-only description of the PC for the host.
function Get-Inventory {
    param([string]$Firmware)
    $sd = Get-SystemDisk
    $disks = @()
    $map = Get-CimLetterMap
    foreach ($d in (Get-DisksSafe)) {
        $parts = @()
        $mbr = @()
        if ([string]$d.PartitionStyle -eq 'MBR') { $mbr = @(Get-MbrEntries ([int]$d.Number)) }
        foreach ($p in (Get-PartitionsSafe $d.Number | Sort-Object PartitionNumber)) {
            $letter = Get-PartLetter ([int]$d.Number) $p $map
            $type = [string]$p.Type
            $e = @($mbr | Where-Object { $_.Offset -eq [long]$p.Offset }) | Select-Object -First 1
            if ($e) { $type = ('MBR 0x{0:X2}' -f $e.Type); if ($e.Active) { $type += ' active' } }
            $free = $null
            if ($letter) { $lv = Get-LetterVolume $letter; if ($lv) { $free = [int]([math]::Floor($lv.SizeRemaining / 1MB)) } }
            $parts += @{ number = [int]$p.PartitionNumber; letter = (Get-Printable $letter 1); size_mb = [math]::Round($p.Size / 1MB); type = (Get-Printable $type 40); free_mb = $free }
        }
        $disks += @{ number = [int]$d.Number; model = (Get-Printable $d.FriendlyName.Trim()); size_gb = [math]::Round($d.Size / 1GB, 1); style = (Get-Printable ([string]$d.PartitionStyle) 10); serial = (Get-Printable (("" + $d.SerialNumber).Trim()) 40); unique_id = (Get-Printable (("" + $d.UniqueId).Trim()) 80); bus = (Get-Printable ([string]$d.BusType) 20); system = ($d.Number -eq $sd.Disk.Number); partitions = $parts }
    }
    $bl = @()
    foreach ($v in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
        $dl = ([string]$v.DeviceID).Substring(0, 1)
        $st = Get-BitLockerStatus $dl
        $t = 'none'
        if ($null -ne $st) { if ([int]$st -eq 0) { $t = 'off' } elseif ([int]$st -eq 1) { $t = 'on' } else { $t = 'converting' } }
        $bl += @{ drive = $dl; status = $t }
    }
    $ips = @()
    try { $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress }) } catch { }
    $hint = Get-PlanHint $Firmware $sd (Get-BootMode)
    $plan = $hint.plan
    $notes = $hint.notes
    $svc = @()
    foreach ($n in 'vds', 'StorSvc', 'smphost') {
        $st = 'missing'
        try { $st = [string](Get-Service -Name $n -ErrorAction Stop).Status } catch { }
        $svc += @{ name = $n; status = (Get-Printable $st 20) }
    }
    $hn = ([regex]::Replace(("" + $env:COMPUTERNAME), '[^A-Za-z0-9-]', ''))
    if ($hn.Length -gt 15) { $hn = $hn.Substring(0, 15) }
    return @{
        machine = $Script:Opt.MachineId; hostname = $hn; ips = $ips; firmware = $Firmware; secureboot = $(if ($Firmware -eq 'bios') { 'na' } else { Get-SecureBootState })
        bitlocker = $bl; boot_free_mb = (Get-BootFreeMb $Firmware $sd); system_disk = [int]$sd.Disk.Number
        os = (Get-Printable ((Get-CimInstance Win32_OperatingSystem).Caption)); disks = $disks
        model = (Get-MachineModel); cpu = (Get-CpuInfo); ram = (Get-RamInfo); plan = $plan; notes = $notes
        ui_culture = (Get-Printable ((Get-UICulture).Name) 20); services = $svc
    }
}

# Sends the inventory, retrying with backoff until the deadline; $true when the host took it.
function Send-InventoryUntil {
    param($Inv, [datetime]$Deadline)
    $n = 0
    while ((Get-Date) -lt $Deadline) {
        try {
            Send-Json '/inventory' $Inv | Out-Null
            if ($n -gt 0) { Write-Host 'Server reachable again, inventory sent' }
            return $true
        } catch {
            $n++
            if ($n -eq 1) { Write-Host ('Server not reachable, retrying (' + (Get-Date -Format 'HH:mm:ss') + ')') }
            Write-Log ('inventory post: ' + $_.Exception.Message)
            Start-Sleep -Seconds (Get-Backoff $n)
        }
    }
    return $false
}

# Polls the host until it approves; $null at the deadline. A host that restarted and forgot this PC ("unknown")
# gets the inventory again; connection errors never end the wait.
function Wait-Approval {
    param($Inv, [datetime]$Deadline)
    $errs = 0
    $lost = $false
    $lastCount = [datetime]::MinValue
    while ((Get-Date) -lt $Deadline) {
        $pause = $Script:Opt.PollSeconds
        try {
            $r = Invoke-RestMethod -Uri ($Script:Opt.Server + '/approval?machine=' + $Script:Opt.MachineId) -TimeoutSec 15
            $errs = 0
            if ($lost) { $lost = $false; Write-Host 'Server reachable again' }
            if ($r.state -ceq 'approved') { return $r }
            if ($r.state -ceq 'unknown' -and $null -ne $Inv) {
                try {
                    Send-Json '/inventory' $Inv | Out-Null
                    Write-Host 'Server did not know this PC, inventory sent again'
                    Write-Log 'inventory sent again (host did not know this PC)'
                } catch { Write-Log ('inventory again: ' + $_.Exception.Message) }
            }
        } catch {
            $errs++
            $pause = Get-Backoff $errs
            Write-Log ('approval poll: ' + $_.Exception.Message)
            if (-not $lost) { $lost = $true; Write-Host ('Server not reachable, retrying (' + (Get-Date -Format 'HH:mm:ss') + ')') }
        }
        Invoke-StatusFlush
        $left = ($Deadline - (Get-Date)).TotalSeconds
        if ($left -le 0) { break }
        if (((Get-Date) - $lastCount).TotalSeconds -ge 300) {
            Write-Host ('Waiting for approval, ' + [int][math]::Ceiling($left / 60) + ' min left')
            $lastCount = Get-Date
        }
        Start-Sleep -Seconds ([math]::Max(1, [math]::Min($pause, [math]::Ceiling($left))))
    }
    return $null
}

# One HTTP GET stream starting at byte From (Range). Replaced by a mock in the tests.
function Open-HttpStream {
    param([string]$Url, [long]$From)
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Proxy = $null
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    if ($From -gt 0) { $req.AddRange($From) }
    $resp = $req.GetResponse()
    return @{ Stream = $resp.GetResponseStream(); Response = $resp; Resumed = ([int]$resp.StatusCode -eq 206) }
}

# Downloads Url to Path (Total bytes) with Range resume and backoff until the deadline; $true when complete.
function Receive-File {
    param([string]$Url, [string]$Path, [long]$Total, [datetime]$Deadline)
    $attempt = 0
    while ($true) {
        $have = 0L
        if (Test-Path -LiteralPath $Path) { $have = (Get-Item -LiteralPath $Path).Length }
        if ($have -eq $Total) { return $true }
        if ($have -gt $Total) { Remove-Item -LiteralPath $Path -Force; $have = 0 }
        if ((Get-Date) -ge $Deadline) { return $false }
        try {
            $h = Open-HttpStream $Url $have
            $mode = [IO.FileMode]::Append
            if ($have -gt 0 -and -not $h.Resumed) { $mode = [IO.FileMode]::Create }
            $fs = New-Object IO.FileStream($Path, $mode, [IO.FileAccess]::Write)
            try {
                $buf = New-Object byte[] 1048576
                while (($n = $h.Stream.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $n) }
            } finally {
                $fs.Dispose()
                $h.Stream.Dispose()
                if ($h.Response) { $h.Response.Close() }
            }
            $attempt = 0
        } catch {
            $attempt++
            Write-Log ('download: ' + $_.Exception.Message)
            Start-Sleep -Seconds (Get-Backoff $attempt)
        }
        Invoke-StatusFlush
    }
}

# Downloads and verifies the payload; returns the folder holding payload\. The host may come and go meanwhile.
function Get-RemotePayload {
    $zip = Join-Path $Script:Here 'payload.zip'
    $dir = Join-Path $Script:Here 'payload-files'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $deadline = (Get-Date).AddMinutes($Script:Opt.DownloadTimeoutMinutes)
    $ok = $false
    while (-not $ok) {
        if (-not (Receive-File ($Script:Opt.Server + '/payload.zip') $zip $Script:Opt.PayloadBytes $deadline)) { Stop-Script 'the payload download did not finish in time; nothing was changed' $Script:Exit.Payload }
        $h = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ceq $Script:Opt.PayloadSha256) { $ok = $true } else {
            Write-Log 'payload checksum mismatch: downloading again'
            Remove-Item -LiteralPath $zip -Force
        }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    Remove-Item -LiteralPath $zip -Force
    return (Join-Path $dir 'unitotem-windows-installer\payload')
}

# The PC's public key from the host (retried; nothing is changed on the PC before it arrives).
function Get-RemoteKey {
    $deadline = (Get-Date).AddMinutes($Script:Opt.DownloadTimeoutMinutes)
    $n = 0
    while ((Get-Date) -lt $deadline) {
        try { return ([string](Invoke-RestMethod -Uri ($Script:Opt.Server + '/key?machine=' + $Script:Opt.MachineId) -TimeoutSec 15)).Trim() } catch {
            $n++
            Write-Log ('key fetch: ' + $_.Exception.Message)
            Start-Sleep -Seconds (Get-Backoff $n)
        }
    }
    Stop-Script 'cannot fetch the OTA key from the host; nothing was changed' $Script:Exit.Server
}

function Invoke-Remote {
    if (-not (Test-FullMatch $Script:Opt.Server $Script:Re.Server)) { Stop-Script 'invalid server address' $Script:Exit.Usage }
    if (-not (Test-FullMatch $Script:Opt.PayloadSha256 $Script:Re.Hash)) { Stop-Script 'invalid payload checksum' $Script:Exit.Usage }
    if (-not (Test-IsAdmin)) { Stop-Script 'Run as administrator' $Script:Exit.NotAdmin }
    [Net.WebRequest]::DefaultWebProxy = $null
    $fw = Get-FirmwareKind
    if ($fw -ne 'uefi' -and $fw -ne 'bios') { Stop-Script 'cannot tell the firmware type' $Script:Exit.Unsupported }
    Set-Step 'read the machine id'
    $Script:Opt.MachineId = Get-MachineId
    Set-Step 'inventory'
    $inv = Get-Inventory $fw
    $deadline = (Get-Date).AddMinutes($Script:Opt.TimeoutMinutes)
    Set-Step 'send the inventory'
    if (-not (Send-InventoryUntil $inv $deadline)) { Stop-Script 'no approval from the host (it did not answer); nothing was changed' $Script:Exit.NoApproval }
    if ($inv.plan.where -eq 'none') { Stop-Script ('cannot install: ' + $inv.plan.reason) $Script:Exit.Unsupported }
    Set-Step 'wait for approval'
    Say ('Inventory sent. Waiting for approval on the host (up to ' + $Script:Opt.TimeoutMinutes + ' min). Nothing has been changed.')
    $ap = Wait-Approval $inv $deadline
    if ($null -eq $ap) { Stop-Script 'no approval from the host; nothing was changed' $Script:Exit.NoApproval }
    $sd = Get-SystemDisk
    # The host's approval names machine, disk number and serial; this PC checks all three against itself.
    $serial = (("" + $sd.Disk.SerialNumber).Trim())
    if ([string]$ap.machine -cne $Script:Opt.MachineId -or [int]$ap.disk -ne [int]$sd.Disk.Number -or [string]$ap.serial -cne (Get-Printable $serial 40)) { Stop-Script 'the approval does not match this PC and disk' $Script:Exit.NotConfirmed }
    $word = Get-ConfirmWord $env:COMPUTERNAME $sd.Disk.Number $serial
    Say 'Approved.'
    Set-Step 'download the payload'
    $pd = Get-RemotePayload
    Set-Step 'fetch the OTA key'
    # The public key of this PC comes from the host after the approval; it is not part of the payload.
    $key = Join-Path $pd 'authorized_key.pub'
    $line = Get-RemoteKey
    [IO.File]::WriteAllText($key, ($line.Trim() + "`n"), (New-Object Text.UTF8Encoding($false)))
    $Script:Opt.PayloadDir = $pd
    $Script:Opt.AuthorizedKey = $key
    $Script:Opt.Unattended = $true
    $Script:Opt.Reboot = $true
    $Script:Opt.Disk = [int]$sd.Disk.Number
    $Script:Opt.ConfirmToken = $word
    # From here on the host is not needed: file copies, bcdedit and the restart run from what is already local.
    Set-Step 'prepare the boot files'
    if ($fw -eq 'bios') { Invoke-InstallBios } else { Invoke-Install }
}

function Main {
    if ($Script:Opt.Remote) { Invoke-Remote; return }
    if ($Script:Opt.Unattended -and -not $Script:Opt.Undo -and (($Script:Opt.Disk -lt 0) -or (-not $Script:Opt.WhatIf -and -not $Script:Opt.ConfirmToken))) { Stop-Script '-Unattended needs -Disk and -ConfirmToken' $Script:Exit.Usage }
    if ($Script:Opt.Unattended -and $Script:Opt.ConfirmToken -and -not (Test-FullMatch $Script:Opt.ConfirmToken 'WIPE-[A-Z0-9-]{1,40}-DISK[0-9]{1,4}-[A-Z0-9]{1,8}')) { Stop-Script 'invalid -ConfirmToken' $Script:Exit.Usage }
    if ($Script:Opt.Unattended) { $Script:Status.Mode = '' }
    if (-not (Test-IsAdmin)) { Stop-Script 'Run as administrator' $Script:Exit.NotAdmin }
    Say ('Install-UniTotem ' + (Get-Date -Format 's'))
    $fw = Get-FirmwareKind
    if ($fw -ne 'uefi' -and $fw -ne 'bios') { Stop-Script 'cannot tell the firmware type' $Script:Exit.Unsupported }
    try { $null = Get-Disk | Select-Object -First 1 } catch { Stop-Script 'the storage service is unavailable; restart Windows in normal mode' $Script:Exit.Unsupported }
    if ($Script:Opt.Undo) { Invoke-Undo } elseif ($fw -eq 'bios') { Invoke-InstallBios } else { Invoke-Install }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Main } catch {
        $m = [regex]::Match($_.Exception.Message, '\AUNITOTEM_EXIT:([0-9]+)\z')
        if ($m.Success) {
            $global:LASTEXITCODE = [int]$m.Groups[1].Value
            if (-not $Script:Opt.Remote) { exit $global:LASTEXITCODE }
        } else {
            $detail = Format-FailureDetail $_
            Say ('Failed: ' + $detail)
            Write-Status 'failed' $Script:Exit.Failed $detail
            $global:LASTEXITCODE = $Script:Exit.Failed
            if (-not $Script:Opt.Remote) { exit $Script:Exit.Failed }
        }
    }
}
