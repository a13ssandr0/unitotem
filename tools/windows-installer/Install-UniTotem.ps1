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
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 60
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
$Script:Status = [ordered]@{ Result = 'running'; Code = -1; Message = ''; Mode = ''; DiskNumber = $null; DiskSerial = ''; DiskModel = ''; Where = ''; Partition = ''; BootEntry = ''; ExpectedToken = ''; DryRun = [bool]$WhatIf; Time = '' }
# Parameters as script state, so functions never depend on the caller's scope.
$Script:Opt = @{ WhatIf = [bool]$WhatIf; Undo = [bool]$Undo; Unattended = [bool]$Unattended; Reboot = [bool]$Reboot; Disk = $Disk; ConfirmToken = $ConfirmToken; AuthorizedKey = $AuthorizedKey; PayloadDir = $PayloadDir; DecryptTimeoutMinutes = $DecryptTimeoutMinutes; Remote = [bool]$Remote; Server = $Server; PayloadSha256 = $PayloadSha256; PayloadBytes = $PayloadBytes; PollSeconds = $PollSeconds; TimeoutMinutes = $TimeoutMinutes; MachineId = '' }
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
    try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding ASCII } catch { }
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
    try { ($Script:Status | ConvertTo-Json) | Set-Content -LiteralPath $Script:StatusFile -Encoding ASCII } catch { Write-Log ('status: ' + $_.Exception.Message) }
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
    $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='" + $Letter + ":'") -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $null }
    $r = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    if ($r.ReturnValue -ne 0) { return $null }
    return [int]$r.ConversionStatus
}
# Percent encrypted (0-100) of a volume, $null when unknown.
function Get-BitLockerPercent {
    param([string]$Letter)
    if (-not (Test-FullMatch $Letter $Script:Re.Letter)) { throw 'invalid letter' }
    $v = Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='" + $Letter + ":'") -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $null }
    $r = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
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

function Get-SystemDisk {
    $letter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
    if (-not (Test-FullMatch $letter $Script:Re.Letter)) { throw 'system drive not recognised' }
    $part = Get-Partition -DriveLetter $letter
    $disk = Get-Disk -Number $part.DiskNumber
    if (-not (Test-FullMatch ([string]$disk.Number) $Script:Re.Number)) { throw 'invalid disk number' }
    return @{ Letter = $letter; Part = $part; Disk = $disk }
}

function Show-Disk {
    param($Disk)
    Say ('Disk {0}: {1}, {2} GB, {3}, serial {4}' -f $Disk.Number, $Disk.FriendlyName.Trim(), [math]::Round($Disk.Size / 1GB, 1), $Disk.PartitionStyle, ("" + $Disk.SerialNumber).Trim())
    foreach ($p in (Get-Partition -DiskNumber $Disk.Number | Sort-Object PartitionNumber)) {
        $l = ''
        if ($p.DriveLetter) { $l = [string]$p.DriveLetter + ':' }
        Say ('  #{0} {1,-5} {2,9} MB  {3}' -f $p.PartitionNumber, $l, [math]::Round($p.Size / 1MB), $p.Type)
    }
}

function Find-OtaPartition {
    param([int]$DiskNumber)
    return @(Get-Partition -DiskNumber $DiskNumber | Where-Object {
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
    $existing = @(Find-OtaPartition $Sd.Disk.Number)
    if ($existing.Count -eq 0) {
        Resize-Partition -DriveLetter $Sd.Letter -Size ($Sd.Part.Size - $PartBytes)
        $np = New-Partition -DiskNumber $Sd.Disk.Number -Size $PartBytes -AssignDriveLetter
    } else {
        $np = $existing[0]
        if (-not $np.DriveLetter) {
            Add-PartitionAccessPath -InputObject $np -AssignDriveLetter
            $np = Get-Partition -DiskNumber $Sd.Disk.Number -PartitionNumber $np.PartitionNumber
        }
    }
    $pl = [string]$np.DriveLetter
    if (-not (Test-FullMatch $pl $Script:Re.Letter)) { throw 'new partition has no drive letter' }
    $vol = Get-Volume -DriveLetter $pl
    if ($vol.FileSystem -ne 'FAT32' -or $vol.FileSystemLabel -cne $Script:Label) {
        Format-Volume -DriveLetter $pl -FileSystem FAT32 -NewFileSystemLabel $Script:Label -Confirm:$false | Out-Null
    }
    if (-not (Disable-Volume $pl 600)) { throw 'the new partition stays encrypted' }
    if ((Get-Volume -DriveLetter $pl).FileSystem -ne 'FAT32') { throw 'the new partition is not readable FAT32' }
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
        $dir = $sysLetter + ':\' + $Script:BiosDir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
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
            $c = $env:SystemDrive.Substring(0, 1)
            Resize-Partition -DriveLetter $c -Size (Get-PartitionSupportedSize -DriveLetter $c).SizeMax
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
        $sup = Get-PartitionSupportedSize -DriveLetter $sd.Letter
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
# kernel and initrd from NTFS or FAT32. They go on the active (boot) partition when they fit, else on a new FAT32.
function Invoke-InstallBios {
    $PayloadDir = $Script:Opt.PayloadDir
    if (-not $PayloadDir) { $PayloadDir = Join-Path $Script:Here 'payload' }
    try { $sums = Get-Payload $PayloadDir 'bios' } catch { Stop-Script ('payload: ' + $_.Exception.Message) $Script:Exit.Payload }
    $kiBytes = 0L
    foreach ($n in @('vmlinuz', 'initrd.img')) { $kiBytes += (Get-Item -LiteralPath (Join-Path $PayloadDir $n)).Length }
    $token = Get-TokenFromFile $Script:Opt.AuthorizedKey

    $sd = Get-SystemDisk
    if ([string]$sd.Disk.PartitionStyle -ne 'MBR') { Stop-Script 'the system disk is not MBR' $Script:Exit.Unsupported }
    $active = @(Get-Partition -DiskNumber $sd.Disk.Number | Where-Object { $_.IsActive })
    if ($active.Count -ne 1) { Stop-Script 'no single active (boot) partition on the system disk' $Script:Exit.Unsupported }
    $ap = $active[0]
    $assigned = $false
    if ($ap.DriveLetter) { $sysLetter = [string]$ap.DriveLetter } else {
        $sysLetter = Get-FreeLetter (Get-UsedLetters)
        Add-PartitionAccessPath -DiskNumber $sd.Disk.Number -PartitionNumber $ap.PartitionNumber -AccessPath ($sysLetter + ':')
        $assigned = $true
    }
    if (-not (Test-FullMatch $sysLetter $Script:Re.Letter)) { throw 'boot partition has no drive letter' }
    $guid = $null
    try {
        $vol = Get-Volume -DriveLetter $sysLetter
        $free = [long]$vol.SizeRemaining + (Get-FolderBytes ($sysLetter + ':\' + $Script:BiosDir))
        $where = Get-StorageChoice $free ($kiBytes + 1MB)
        if ($vol.FileSystem -notin 'NTFS', 'FAT32') { $where = 'new' }
        $Script:Status.Mode = 'bios'; $Script:Status.Where = $where
        $partBytes = Get-PartitionBytes $kiBytes
        if ($where -eq 'new') {
            if (@(Get-Partition -DiskNumber $sd.Disk.Number).Count -ge 4 -and @(Find-OtaPartition $sd.Disk.Number).Count -eq 0) { Stop-Script 'the MBR disk has no free primary partition slot' $Script:Exit.Unsupported }
            if (@(Find-OtaPartition $sd.Disk.Number).Count -eq 0) {
                $sup = Get-PartitionSupportedSize -DriveLetter $sd.Letter
                if (-not (Test-ShrinkFeasible $sd.Part.Size $sup.SizeMin $partBytes)) { Stop-Script 'C: cannot shrink enough; free disk space first' $Script:Exit.Unsupported }
            }
        }
        $bl = Get-BitLockerStatus $sysLetter
        $ctx = @{ Undo = $false; Mode = 'bios'; Where = $where; NeededBytes = $kiBytes; PartBytes = $partBytes; Token = $token }
        Say 'Secure Boot: not applicable (legacy BIOS)'
        Say ('Boot partition {0}: free {1} MiB, {2}' -f $sysLetter, [math]::Round($free / 1MB), $vol.FileSystem)
        Show-Disk $sd.Disk
        Say 'UniTotem will ERASE this whole disk when the host starts the install. Windows will be gone.'
        Show-Plan $ctx
        Confirm-Erase $sd.Disk
        if ($Script:Opt.WhatIf) { Say 'Dry run: nothing changed.'; Write-Status 'dry-run' 0 'plan printed'; return }

        if ($where -eq 'boot') {
            # The boot partition is left unencrypted by design; if it is not, GRUB cannot read it.
            if (-not (Disable-Volume $sysLetter ($Script:Opt.DecryptTimeoutMinutes * 60))) { Stop-Script ('decryption of the boot partition did not finish in ' + $Script:Opt.DecryptTimeoutMinutes + ' min; run this script again to continue') $Script:Exit.DecryptTimeout }
            $kletter = $sysLetter
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
        $img = $sysLetter + ':\' + $Script:BiosImage
        Copy-Item -LiteralPath (Join-Path $PayloadDir 'g2.img') -Destination $img -Force
        Test-HashOf (Join-Path $dir 'recovery-vmlinuz') $sums['vmlinuz']
        Test-HashOf (Join-Path $dir 'recovery-initrd.img') $sums['initrd.img']
        Test-HashOf $img $sums['g2.img']
        $o = Invoke-Native 'bcdedit.exe' @('/create', '/d', $Script:EntryName, '/application', 'bootsector')
        $guid = Get-BcdGuid $o
        if ($null -eq $guid) { throw 'bcdedit returned no entry id' }
        Save-State @{ Mode = 'bios'; Guid = $guid; DiskNumber = $sd.Disk.Number; SystemLetter = $sysLetter; Where = $where }
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'device', ('partition=' + $sysLetter + ':')) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/set', $guid, 'path', ('\' + $Script:BiosImage)) | Out-Null
        Invoke-Native 'bcdedit.exe' @('/displayorder', $guid, '/addlast') | Out-Null
        Invoke-Native 'bcdedit.exe' @('/bootsequence', $guid) | Out-Null
    } finally {
        if ($assigned) { try { Remove-PartitionAccessPath -DiskNumber $sd.Disk.Number -PartitionNumber $ap.PartitionNumber -AccessPath ($sysLetter + ':') } catch { Write-Log ('letter: ' + $_.Exception.Message) } }
    }
    Show-Result $guid $token
}

# ---- remote mode (irm | iex): inventory, approval from the host, download, then the normal flow ------------

# Short sanitised text for the JSON sent to the server.
function Get-Printable { param([string]$Text, [int]$Max = 80) $t = [regex]::Replace(("" + $Text), '[^\x20-\x7E]', ''); if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }; return $t }

function Send-Json {
    param([string]$Path, $Body)
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 6 -Compress))
    return (Invoke-RestMethod -Uri ($Script:Opt.Server + $Path) -Method Post -Body $bytes -ContentType 'application/json' -TimeoutSec 15)
}

# Progress line to the server; never fails the run.
function Send-Remote {
    param([string]$Text)
    $level = 'info'
    if ($Text -like 'Stopped:*' -or $Text -like 'Failed:*') { $level = 'error' } elseif ($Text -like 'Ready*') { $level = 'ok' }
    try { Send-Json '/status' @{ machine = $Script:Opt.MachineId; level = $level; text = (Get-Printable $Text 200) } | Out-Null } catch { Write-Log ('status post: ' + $_.Exception.Message) }
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
        $ap = @(Get-Partition -DiskNumber $Sd.Disk.Number | Where-Object { $_.IsActive })
        if ($ap.Count -eq 1 -and $ap[0].DriveLetter) { return [int]([math]::Floor((Get-Volume -DriveLetter $ap[0].DriveLetter).SizeRemaining / 1MB)) }
    } catch { Write-Log ('boot free space: ' + $_.Exception.Message) }
    return $null
}

# Read-only description of the PC for the host.
function Get-Inventory {
    param([string]$Firmware)
    $sd = Get-SystemDisk
    $disks = @()
    foreach ($d in (Get-Disk)) {
        $parts = @()
        foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)) {
            $parts += @{ number = [int]$p.PartitionNumber; letter = (Get-Printable ([string]$p.DriveLetter) 1); size_mb = [math]::Round($p.Size / 1MB); type = (Get-Printable ([string]$p.Type) 40) }
        }
        $disks += @{ number = [int]$d.Number; model = (Get-Printable $d.FriendlyName.Trim()); size_gb = [math]::Round($d.Size / 1GB, 1); style = (Get-Printable ([string]$d.PartitionStyle) 10); serial = (Get-Printable (("" + $d.SerialNumber).Trim()) 40); unique_id = (Get-Printable (("" + $d.UniqueId).Trim()) 80); bus = (Get-Printable ([string]$d.BusType) 20); system = ($d.Number -eq $sd.Disk.Number); partitions = $parts }
    }
    $bl = @()
    foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
        $st = Get-BitLockerStatus ([string]$v.DriveLetter)
        $t = 'none'
        if ($null -ne $st) { if ([int]$st -eq 0) { $t = 'off' } elseif ([int]$st -eq 1) { $t = 'on' } else { $t = 'converting' } }
        $bl += @{ drive = ([string]$v.DriveLetter); status = $t }
    }
    $ips = @()
    try { $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress }) } catch { }
    $hn = ([regex]::Replace(("" + $env:COMPUTERNAME), '[^A-Za-z0-9-]', ''))
    if ($hn.Length -gt 15) { $hn = $hn.Substring(0, 15) }
    return @{
        machine = $Script:Opt.MachineId; hostname = $hn; ips = $ips; firmware = $Firmware; secureboot = (Get-SecureBootState)
        bitlocker = $bl; boot_free_mb = (Get-BootFreeMb $Firmware $sd); system_disk = [int]$sd.Disk.Number
        os = (Get-Printable ((Get-CimInstance Win32_OperatingSystem).Caption)); disks = $disks
    }
}

# Polls the host until it approves; $null on timeout.
function Wait-Approval {
    $end = (Get-Date).AddMinutes($Script:Opt.TimeoutMinutes)
    while ((Get-Date) -lt $end) {
        try {
            $r = Invoke-RestMethod -Uri ($Script:Opt.Server + '/approval?machine=' + $Script:Opt.MachineId) -TimeoutSec 15
            if ($r.state -ceq 'approved') { return $r }
        } catch { Write-Log ('approval poll: ' + $_.Exception.Message) }
        Start-Sleep -Seconds $Script:Opt.PollSeconds
    }
    return $null
}

# Downloads and verifies the payload; returns the folder holding payload\.
function Get-RemotePayload {
    $zip = Join-Path $Script:Here 'payload.zip'
    $dir = Join-Path $Script:Here 'payload-files'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        $wc = New-Object Net.WebClient
        $wc.Proxy = $null
        try { $wc.DownloadFile(($Script:Opt.Server + '/payload.zip'), $zip) } catch { Write-Log ('download: ' + $_.Exception.Message); continue } finally { $wc.Dispose() }
        $h = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ceq $Script:Opt.PayloadSha256 -and (Get-Item -LiteralPath $zip).Length -eq $Script:Opt.PayloadBytes) { $ok = $true }
    }
    if (-not $ok) { Stop-Script 'the payload download failed its checksum' $Script:Exit.Payload }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    Remove-Item -LiteralPath $zip -Force
    return (Join-Path $dir 'unitotem-windows-installer\payload')
}

function Invoke-Remote {
    if (-not (Test-FullMatch $Script:Opt.Server $Script:Re.Server)) { Stop-Script 'invalid server address' $Script:Exit.Usage }
    if (-not (Test-FullMatch $Script:Opt.PayloadSha256 $Script:Re.Hash)) { Stop-Script 'invalid payload checksum' $Script:Exit.Usage }
    if (-not (Test-IsAdmin)) { Stop-Script 'Run as administrator' $Script:Exit.NotAdmin }
    [Net.WebRequest]::DefaultWebProxy = $null
    $fw = Get-FirmwareKind
    if ($fw -ne 'uefi' -and $fw -ne 'bios') { Stop-Script 'cannot tell the firmware type' $Script:Exit.Unsupported }
    try { $null = Get-Disk | Select-Object -First 1 } catch { Stop-Script 'the storage service is unavailable; restart Windows in normal mode' $Script:Exit.Unsupported }
    $Script:Opt.MachineId = Get-MachineId
    $inv = Get-Inventory $fw
    try { Send-Json '/inventory' $inv | Out-Null } catch { Stop-Script ('cannot reach the host: ' + $_.Exception.Message) $Script:Exit.Server }
    Say ('Inventory sent. Waiting for approval on the host (up to ' + $Script:Opt.TimeoutMinutes + ' min). Nothing has been changed.')
    $ap = Wait-Approval
    if ($null -eq $ap) { Stop-Script 'no approval from the host; nothing was changed' $Script:Exit.NoApproval }
    $sd = Get-SystemDisk
    $word = Get-ConfirmWord $env:COMPUTERNAME $sd.Disk.Number (("" + $sd.Disk.SerialNumber).Trim())
    if ([int]$ap.disk -ne [int]$sd.Disk.Number -or -not ([string]$ap.word -ceq $word)) { Stop-Script 'the approval does not match this PC and disk' $Script:Exit.NotConfirmed }
    Say 'Approved.'
    $pd = Get-RemotePayload
    $Script:Opt.PayloadDir = $pd
    $key = Join-Path $pd 'authorized_key.pub'
    if (Test-Path -LiteralPath $key) { $Script:Opt.AuthorizedKey = $key }
    $Script:Opt.Unattended = $true
    $Script:Opt.Reboot = $true
    $Script:Opt.Disk = [int]$sd.Disk.Number
    $Script:Opt.ConfirmToken = $word
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
            Say ('Failed: ' + $_.Exception.Message)
            Write-Status 'failed' $Script:Exit.Failed $_.Exception.Message
            $global:LASTEXITCODE = $Script:Exit.Failed
            if (-not $Script:Opt.Remote) { exit $Script:Exit.Failed }
        }
    }
}
