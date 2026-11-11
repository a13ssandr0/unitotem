# Pester 5 tests of the pure functions; system calls are never made.
#   pwsh -c "Invoke-Pester ./Install-UniTotem.Tests.ps1 -Output Detailed"
BeforeAll {
    . (Join-Path $PSScriptRoot 'Install-UniTotem.ps1')
    $script:good = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl user@host'
}
Describe 'Test-FullMatch' {
    It 'matches the whole string only' {
        Test-FullMatch 'A' '[A-Z]' | Should -BeTrue
        Test-FullMatch 'AB' '[A-Z]' | Should -BeFalse
        Test-FullMatch "A`n" '[A-Z]' | Should -BeFalse
        Test-FullMatch $null '[A-Z]' | Should -BeFalse
        Test-FullMatch 'xA' '[A-Z]' | Should -BeFalse
    }
    It 'alternations cannot escape the anchors' {
        Test-FullMatch 'ab' 'a|ab' | Should -BeTrue
        Test-FullMatch 'abc' 'a|ab' | Should -BeFalse
    }
}
Describe 'Get-BcdGuid' {
    It 'finds the id in localized output' {
        Get-BcdGuid @('La voce e'' stata copiata in {0a1b2c3d-1111-2222-3333-444455556666}.') | Should -Be '{0a1b2c3d-1111-2222-3333-444455556666}'
        Get-BcdGuid @('The entry was successfully copied to {0A1B2C3D-1111-2222-3333-444455556666}.') | Should -Be '{0A1B2C3D-1111-2222-3333-444455556666}'
    }
    It 'rejects output without an id' {
        Get-BcdGuid @('error {nope}') | Should -BeNullOrEmpty
        Get-BcdGuid @('') | Should -BeNullOrEmpty
    }
}
Describe 'Get-PartitionBytes' {
    It 'is at least 256 MiB' { Get-PartitionBytes 1MB | Should -Be 256MB }
    It 'covers payload plus headroom, rounded to 16 MiB' {
        $p = 240MB
        $r = Get-PartitionBytes $p
        $r | Should -BeGreaterOrEqual ($p + 64MB)
        ($r % 16MB) | Should -Be 0
        $r | Should -Be 304MB
    }
}
Describe 'Test-ShrinkFeasible' {
    It 'needs the space plus a margin' {
        Test-ShrinkFeasible 100GB 40GB 304MB | Should -BeTrue
        Test-ShrinkFeasible 100GB 99.9GB 304MB | Should -BeFalse
        Test-ShrinkFeasible 1000MB 600MB 304MB | Should -BeTrue
        Test-ShrinkFeasible 1000MB 700MB 304MB | Should -BeFalse
    }
}
Describe 'Key handling' {
    It 'accepts one ed25519 line, ignoring comments and blanks' {
        Get-KeyLine @('# c', '', $good) | Should -Be $good
    }
    It 'refuses everything else' {
        Get-KeyLine @() | Should -BeNullOrEmpty
        Get-KeyLine @($good, $good) | Should -BeNullOrEmpty
        Get-KeyLine @('ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ user') | Should -BeNullOrEmpty
        Get-KeyLine @('command="x" ' + $good) | Should -BeNullOrEmpty
        Get-KeyLine @($good + "`tx") | Should -BeNullOrEmpty
        Get-KeyLine @('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIshort') | Should -BeNullOrEmpty
    }
    It 'token decodes to "type blob" without the comment' {
        $t = ConvertTo-AuthKeyToken $good
        [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($t)) | Should -Be 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
    }
    It 'refuses a bad line' { { ConvertTo-AuthKeyToken 'x y' } | Should -Throw }
}
Describe 'New-GrubCfg token' {
    BeforeAll { $script:tpl = "linux /vmlinuz unitotem.ota=1 console=tty0@AUTHKEY@`ninitrd /initrd.img`n" }
    It 'open mode leaves the line unchanged' { New-GrubCfg $tpl '' | Should -Be "linux /vmlinuz unitotem.ota=1 console=tty0`ninitrd /initrd.img`n" }
    It 'adds the token' { New-GrubCfg $tpl 'QUJD' | Should -Match 'console=tty0 unitotem\.ota\.authkey=QUJD\n' }
    It 'refuses an injected value' {
        { New-GrubCfg $tpl "QUJD`nboot" } | Should -Throw
        { New-GrubCfg $tpl 'a b' } | Should -Throw
    }
}
Describe 'Read-Sums' {
    It 'parses sha256sum lines' { (Read-Sums @(('a' * 64) + '  vmlinuz'))['vmlinuz'] | Should -Be ('a' * 64) }
    It 'refuses malformed lines' {
        { Read-Sums @('zz  vmlinuz') } | Should -Throw
        { Read-Sums @(('a' * 64) + '  ../x') } | Should -Throw
    }
}
Describe 'Get-FreeLetter' {
    It 'takes Z first' { Get-FreeLetter @('C') | Should -Be 'Z' }
    It 'skips used ones' { Get-FreeLetter @('Z', 'Y') | Should -Be 'X' }
    It 'fails when none is free' { { Get-FreeLetter ([string[]][char[]](68..90)) } | Should -Throw }
}
Describe 'Test-NeedsDecrypt' {
    It 'is false for decrypted or no BitLocker' {
        Test-NeedsDecrypt 0 | Should -BeFalse
        Test-NeedsDecrypt $null | Should -BeFalse
    }
    It 'is true for encrypted and in-progress states' { foreach ($i in 1..5) { Test-NeedsDecrypt $i | Should -BeTrue } }
}
Describe 'Get-StorageChoice' {
    It 'uses the boot partition only with a 16 MiB margin' {
        Get-StorageChoice 300MB 240MB | Should -Be 'boot'
        Get-StorageChoice 256MB 240MB | Should -Be 'boot'
        Get-StorageChoice 255MB 240MB | Should -Be 'new'
        Get-StorageChoice 61MB 240MB | Should -Be 'new'
        Get-StorageChoice 0 1 | Should -Be 'new'
    }
}
Describe 'New-GrubCfg directory' {
    It 'substitutes a validated directory' {
        New-GrubCfg 'a @DIR@/k@AUTHKEY@' '' '/EFI/unitotem' | Should -Be 'a /EFI/unitotem/k'
        New-GrubCfg 'a @DIR@/k' '' '' | Should -Be 'a /k'
    }
    It 'refuses a bad directory' {
        { New-GrubCfg 'a @DIR@' '' '/a b' } | Should -Throw
        { New-GrubCfg 'a @DIR@' '' '/a;boot' } | Should -Throw
        { New-GrubCfg 'a @DIR@' '' 'a' } | Should -Throw
    }
    It 'real templates render' {
        $t = Get-Content -Raw (Join-Path $PSScriptRoot 'grub.cfg.template')
        (New-GrubCfg $t 'QUJD' '/EFI/unitotem') | Should -Match 'search --no-floppy --file --set=root /EFI/unitotem/unitotem-vmlinuz'
        (New-GrubCfg $t 'QUJD' '/EFI/unitotem') | Should -Not -Match '@'
        $b = Get-Content -Raw (Join-Path $PSScriptRoot 'menu.lst.template')
        (New-GrubCfg $b '') | Should -Not -Match '@'
    }
}
Describe 'Build-Plan' {
    It 'UEFI, boot partition: no shrink, no BitLocker action' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'uefi'; Where = 'boot'; NeededBytes = 240MB; PartBytes = 304MB; Token = 'QUJD' }) -join "`n"
        $p | Should -Match 'place=boot_partition c=untouched bitlocker=untouched'
        $p | Should -Not -Match 'shrink'
        $p | Should -Match 'ota_login=key'
    }
    It 'UEFI, new partition: shrink and BitLocker only on the new partition' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'uefi'; Where = 'new'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n"
        $p | Should -Match 'shrink_c_mb=304'
        $p | Should -Match 'bitlocker=off_on_new_only'
        $p | Should -Match 'ota_login=open'
        $p | Should -Not -Match 'Decrypt C'
    }
    It 'BIOS plan' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'bios'; Where = 'boot'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n"
        $p | Should -Match 'loader=grldr\.mbr'
        $p | Should -Not -Match 'shrink'
    }
    It 'plan lines hold facts, not sentences' {
        foreach ($w in 'boot', 'cdrive', 'new') {
            foreach ($l in (Build-Plan @{ Undo = $false; Mode = 'bios'; Where = $w; NeededBytes = 240MB; PartBytes = 304MB; Token = $null })) {
                $l | Should -Not -Match '\b(the|will|because|please|nothing)\b'
            }
        }
    }
    It 'Undo plans' {
        ((Build-Plan @{ Undo = $true; Mode = 'bios' }) -join "`n") | Should -Match 'remove folder=unitotem'
        ((Build-Plan @{ Undo = $true; Mode = 'uefi' }) -join "`n") | Should -Match 'remove folder=EFI\\unitotem'
    }
}
Describe 'Get-ConfirmWord' {
    It 'is bound to host, disk number and serial' {
        Get-ConfirmWord 'desktop-ABC' 0 'S4EVNX0N123456A ' | Should -Be 'WIPE-DESKTOP-ABC-DISK0-S4EVNX0N'
        Get-ConfirmWord 'pc_1' 2 '' | Should -Be 'WIPE-PC1-DISK2-NOSERIAL'
        Get-ConfirmWord 'A' 1 'ab-12' | Should -Be 'WIPE-A-DISK1-AB12'
        Get-ConfirmWord 'A' 0 'AAAAAAAA' | Should -Not -Be (Get-ConfirmWord 'A' 1 'AAAAAAAA')
        Get-ConfirmWord 'A' 0 'AAAAAAAA' | Should -Not -Be (Get-ConfirmWord 'B' 0 'AAAAAAAA')
        Get-ConfirmWord 'ABCDEFGHIJKLMNOPQRST' 0 'x' | Should -Be 'WIPE-ABCDEFGHIJKLMNO-DISK0-X'
    }
    It 'matches the token pattern checked in Main' { Test-FullMatch (Get-ConfirmWord 'pc-1' 12 'x_y.z9') 'WIPE-[A-Z0-9-]{1,40}-DISK[0-9]{1,4}-[A-Z0-9]{1,8}' | Should -BeTrue }
}
Describe 'Dry run, unattended, mocked system' {
    BeforeAll {
        $script:pd = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:pd | Out-Null
        $lines = @()
        foreach ($n in 'vmlinuz', 'initrd.img', 'shimx64.efi', 'mmx64.efi', 'grubx64.efi') {
            $sz = 200; if ($n -eq 'vmlinuz') { $sz = 10MB }
            [IO.File]::WriteAllBytes((Join-Path $script:pd $n), (New-Object byte[] $sz))
        }
        Copy-Item (Join-Path $PSScriptRoot 'grub.cfg.template') (Join-Path $script:pd 'grub.cfg.template')
        foreach ($n in 'vmlinuz', 'initrd.img', 'shimx64.efi', 'mmx64.efi', 'grubx64.efi', 'grub.cfg.template') {
            $lines += ((Get-FileHash (Join-Path $script:pd $n) -Algorithm SHA256).Hash.ToLower() + '  ' + $n)
        }
        Set-Content (Join-Path $script:pd 'SHA256SUMS') $lines
        $script:Here = $script:pd
        $script:StatusFile = Join-Path $script:pd 'status.json'
        $script:LogFile = Join-Path $script:pd 'log.txt'
        $script:Opt.PayloadDir = $script:pd
    }
    BeforeEach {
        $env:COMPUTERNAME = 'TESTPC'
        $script:Opt.WhatIf = $true
        $script:Opt.Unattended = $true
        $script:Opt.Disk = 0
        Mock Get-SystemDisk { @{ Letter = 'C'; Part = [pscustomobject]@{ Size = 100GB; PartitionNumber = 3 }; Disk = [pscustomobject]@{ Number = 0; FriendlyName = 'Test disk'; PartitionStyle = 'GPT'; SerialNumber = 'ABCD1234XY'; Size = 100GB } } }
        Mock Show-Disk { }
        Mock Mount-Esp { }
        Mock Dismount-Esp { }
        Mock Get-UsedLetters { @('C') }
        Mock Find-OtaPartition { @() }
        Mock Get-SecureBootState { 'on' }
        Mock Get-SupportedSize { [pscustomobject]@{ SizeMin = 40GB } }
    }
    It 'plans the boot partition when it has room and records the expected token' {
        Mock Get-FreeBytes { 500MB }
        Invoke-Install
        $st = Get-Content (Join-Path $script:pd 'status.json') -Raw | ConvertFrom-Json
        $st.Result | Should -Be 'dry-run'
        $st.Where | Should -Be 'boot'
        $st.ExpectedToken | Should -Be 'WIPE-TESTPC-DISK0-ABCD1234'
    }
    It 'plans a new partition when it has not' {
        Mock Get-FreeBytes { 20MB }
        Invoke-Install
        (Get-Content (Join-Path $script:pd 'status.json') -Raw | ConvertFrom-Json).Where | Should -Be 'new'
    }
    It 'never prompts in unattended mode' {
        { Read-Word 'x' 'y' } | Should -Throw '*unattended*'
    }
    AfterAll { Remove-Item -LiteralPath $script:pd -Recurse -Force }
}

Describe 'System partition without the Storage drive-letter filter' {
    BeforeAll {
        function global:Get-CimInstance { param($ClassName, $Filter, $Namespace) }
        function global:Get-CimAssociatedInstance { param($InputObject, $ResultClassName) }
        function global:Get-Partition { param($DriveLetter, $DiskNumber, $PartitionNumber) }
        function global:Get-Disk { param($Number) }
    }
    BeforeEach {
        $env:SystemDrive = 'C:'
        Mock Get-Disk { [pscustomobject]@{ Number = 2; PartitionStyle = 'GPT' } }
        Mock Get-Partition {
            if ($PSBoundParameters.ContainsKey('DriveLetter')) { throw 'No MSFT_Partition objects found with property DriveLetter equal to C' }
            @([pscustomobject]@{ PartitionNumber = 1; Offset = 1048576; Size = 100MB; IsBoot = $false },
              [pscustomobject]@{ PartitionNumber = 3; Offset = 105906176; Size = 90GB; IsBoot = $true; DiskNumber = 2 })
        }
    }
    It 'finds the partition through CIM and the offset, never by -DriveLetter' {
        Mock Get-LetterPartitionInfo { @{ DiskIndex = 2; Offset = 105906176; Size = 90GB; Index = 2 } }
        $sd = Get-SystemDisk
        $sd.Part.PartitionNumber | Should -Be 3
        $sd.Disk.Number | Should -Be 2
        Should -Invoke Get-Partition -Times 0 -ParameterFilter { $PSBoundParameters.ContainsKey('DriveLetter') }
    }
    It 'falls back to the boot partition when CIM finds nothing' {
        Mock Get-LetterPartitionInfo { $null }
        (Get-SystemDisk).Part.PartitionNumber | Should -Be 3
    }
    It 'fails with a clear message when nothing matches' {
        Mock Get-LetterPartitionInfo { $null }
        Mock Get-Partition { @() }
        { Get-SystemDisk } | Should -Throw '*no partition found*'
    }
    It 'Get-LetterPartitionInfo reads the classic CIM classes' {
        Mock Get-CimInstance { [pscustomobject]@{ DeviceID = 'C:' } }
        Mock Get-CimAssociatedInstance { [pscustomobject]@{ DiskIndex = 1; StartingOffset = 1048576; Size = 50GB; Index = 0 } }
        $i = Get-LetterPartitionInfo 'C'
        $i.DiskIndex | Should -Be 1
        $i.Offset | Should -Be 1048576
    }
    It 'Get-LetterVolume reads Win32_LogicalDisk' {
        Mock Get-CimInstance { [pscustomobject]@{ FileSystem = 'FAT32'; FreeSpace = 123456; Size = 999999; VolumeName = 'UNITOTEMOTA' } }
        $v = Get-LetterVolume 'D'
        $v.FileSystem | Should -Be 'FAT32'
        $v.SizeRemaining | Should -Be 123456
    }
    It 'rejects a bad letter' { { Get-LetterVolume "C:'" } | Should -Throw }
    It 'Select-PartitionByOffset' {
        (Select-PartitionByOffset @([pscustomobject]@{ Offset = 5 }, [pscustomobject]@{ Offset = 9 }) 9).Offset | Should -Be 9
        Select-PartitionByOffset @([pscustomobject]@{ Offset = 5 }) 7 | Should -BeNullOrEmpty
    }
}
Describe 'Format-FailureDetail' {
    It 'carries step, error id, message and statement without comparing localized text' {
        Set-Step 'find the system disk'
        try { Get-Item -LiteralPath '/nonexistent-unitotem-test' -ErrorAction Stop } catch { $e = $_ }
        $d = Format-FailureDetail $e
        $d | Should -Match '^step "find the system disk": '
        $d | Should -Match '\[[A-Za-z]+,'
        $d | Should -Match 'at: .*Get-Item'
    }
}

Describe 'Unicode log transport' {
    BeforeAll {
        $script:msg = 'Nessun oggetto MSFT_Partition trovato con la propriet' + [char]0x00E0 + ' "DriveLetter". ' + [char]0x00C8 + ' gi' + [char]0x00E0 + ' cos' + [char]0x00EC + ' ' + [char]0x20AC
        function global:Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType, $TimeoutSec) }
    }
    It 'Get-Printable keeps Unicode and removes control characters' {
        $e = [char]27
        Get-Printable ('a' + $e + '[31mb' + [char]0x9B + 'c' + [char]7 + $script:msg) 4000 | Should -Be ('a[31mbc' + $script:msg)
    }
    It 'does not cut 3000 characters and marks a cut' {
        (Get-Printable ('x' * 3000) 4000).Length | Should -Be 3000
        Get-Printable ('x' * 5000) 4000 | Should -Be (('x' * 4000) + '...[truncated 1000]')
    }
    It 'Send-Json sends UTF-8 bytes with a charset' {
        $script:Opt.Server = 'http://127.0.0.1:8000'
        Mock Invoke-RestMethod { }
        Send-Json '/status' @{ text = $script:msg } | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            ($Body -is [byte[]]) -and ($ContentType -eq 'application/json; charset=utf-8') -and
            ([Text.Encoding]::UTF8.GetString($Body) -like ('*' + [char]0x00E0 + '*')) -and
            ([Text.Encoding]::UTF8.GetString($Body) -like ('*' + [char]0x20AC + '*'))
        }
    }
    It 'the log file is written as UTF-8' {
        Get-Content (Join-Path $PSScriptRoot 'Install-UniTotem.ps1') -Raw | Should -Match 'Add-Content -LiteralPath .Script:LogFile -Value \(Format-LogLine .Level .Text\) -Encoding UTF8'
    }
}

Describe 'Select-BiosWhere' {
    BeforeAll {
        $script:need = 241MB
        function F($o) { $f = @{ ActiveLetter = ''; ActiveFs = ''; ActiveFree = 0L; CFs = 'NTFS'; CFree = 100GB; CEncrypted = $false; BootMode = 'safe'; PartCount = 3; HasOta = $false }; foreach ($k in $o.Keys) { $f[$k] = $o[$k] }; return $f }
    }
    It 'prefers the active partition when it has room' {
        (Select-BiosWhere (F @{ ActiveLetter = 'S'; ActiveFs = 'NTFS'; ActiveFree = 500MB }) $need).Where | Should -Be 'boot'
    }
    It 'uses C: when System Reserved is too small (the real laptop in Safe Mode)' {
        (Select-BiosWhere (F @{ ActiveLetter = ''; ActiveFree = 0 }) $need).Where | Should -Be 'cdrive'
        (Select-BiosWhere (F @{ ActiveLetter = 'S'; ActiveFs = 'NTFS'; ActiveFree = 20MB }) $need).Where | Should -Be 'cdrive'
    }
    It 'refuses a new partition in Safe Mode' {
        $r = Select-BiosWhere (F @{ CEncrypted = $true }) $need
        $r.Where | Should -Be 'none'
        $r.Reason | Should -Be 'safe_mode_no_partition_has_room'
    }
    It 'new partition only in normal mode and with a free slot' {
        (Select-BiosWhere (F @{ CFree = 1MB; BootMode = 'normal' }) $need).Where | Should -Be 'new'
        (Select-BiosWhere (F @{ CFree = 1MB; BootMode = 'normal'; PartCount = 4 }) $need).Where | Should -Be 'none'
        (Select-BiosWhere (F @{ CFree = 1MB; BootMode = 'normal'; PartCount = 4; HasOta = $true }) $need).Where | Should -Be 'new'
    }
    It 'needs C: to be NTFS' {
        (Select-BiosWhere (F @{ CFs = 'FAT32' }) $need).Where | Should -Be 'none'
    }
    It 'plan text for C:' {
        ((Build-Plan @{ Undo = $false; Mode = 'bios'; Where = 'cdrive'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n") | Should -Match 'partition_changes=none'
    }
}
Describe 'MBR and CIM letters' {
    It 'Get-PartLetter uses the CIM map before the Storage letter' {
        $m = @{ '0:1048576' = 'D' }
        Get-PartLetter 0 ([pscustomobject]@{ Offset = 1048576; DriveLetter = '' }) $m | Should -Be 'D'
        Get-PartLetter 0 ([pscustomobject]@{ Offset = 5; DriveLetter = 'E' }) $m | Should -Be 'E'
        Get-PartLetter 0 ([pscustomobject]@{ Offset = 5; DriveLetter = '' }) $m | Should -Be ''
    }
    It 'machine info fields fall back to unknown' {
        Get-CimField { throw 'no CIM' } | Should -Be 'unknown'
        Get-CimField { '  ' } | Should -Be 'unknown'
        Get-CimField { 'LENOVO 20XW' } | Should -Be 'LENOVO 20XW'
    }
}

Describe 'Host restarts and outages' {
    BeforeAll {
        Add-Type -TypeDefinition @'
using System; using System.IO;
public class FailingStream : MemoryStream {
    private long limit;
    public FailingStream(byte[] b, long limit) : base(b) { this.limit = limit; }
    public override int Read(byte[] buffer, int offset, int count) {
        if (Position >= limit) throw new IOException("connection lost");
        return base.Read(buffer, offset, (int)Math.Min(count, limit - Position));
    }
}
'@
        function global:Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType, $TimeoutSec) }
    }
    BeforeEach {
        Mock Start-Sleep { }
        $script:LogFile = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-log-' + [guid]::NewGuid() + '.txt')
        $script:Opt.Server = 'http://127.0.0.1:8000'
        $script:Opt.MachineId = '3f2a9c1e-0000-4000-8000-123456789abc'
        $script:Opt.PollSeconds = 1
        $script:StatusQueue.Clear(); $script:StatusFails = 0; $script:StatusNext = [datetime]::MinValue
    }
    AfterEach { Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue }

    It 'Get-Backoff is 5, 10, 20, 30, 30' {
        (1..6 | ForEach-Object { Get-Backoff $_ }) -join ',' | Should -Be '5,10,20,30,30,30'
    }
    It 'status posts never throw, are queued, and are delivered in order when the host is back' {
        $script:sent = New-Object System.Collections.Generic.List[string]
        $script:up = $false
        Mock Send-Json { if (-not $script:up) { throw 'host down' }; $script:sent.Add([string]$Body.text) }
        { Send-Remote 'one'; Send-Remote 'two'; Send-Remote 'three' } | Should -Not -Throw
        $script:StatusQueue.Count | Should -Be 3
        $script:up = $true
        Invoke-StatusFlush -Force
        ($script:sent -join ',') | Should -Be 'one,two,three'
        $script:StatusQueue.Count | Should -Be 0
    }
    It 'the status queue is bounded' {
        Mock Send-Json { throw 'host down' }
        1..250 | ForEach-Object { Send-Remote ('line ' + $_) }
        $script:StatusQueue.Count | Should -Be 200
        $script:StatusQueue.Peek().text | Should -Be 'line 51'
    }
    It 'Wait-Approval survives errors, sends the inventory again on "unknown" and returns the approval' {
        $script:calls = 0
        $script:resent = 0
        Mock Invoke-RestMethod {
            $script:calls++
            switch ($script:calls) {
                1 { throw 'connection refused' }
                2 { throw 'connection refused' }
                3 { [pscustomobject]@{ state = 'unknown' } }
                4 { [pscustomobject]@{ state = 'wait' } }
                default { [pscustomobject]@{ state = 'approved'; machine = $script:Opt.MachineId; disk = 0; serial = 'S' } }
            }
        }
        Mock Send-Json { $script:resent++ }
        $r = Wait-Approval @{ machine = 'x' } ((Get-Date).AddMinutes(5))
        $r.state | Should -Be 'approved'
        $script:resent | Should -Be 1
    }
    It 'Wait-Approval returns $null at the deadline and never throws while the host is down' {
        Mock Invoke-RestMethod { throw 'connection refused' }
        $r = $null
        { $r = Wait-Approval @{ machine = 'x' } ((Get-Date).AddSeconds(1)) } | Should -Not -Throw
        $r | Should -BeNullOrEmpty
    }
    It 'Send-InventoryUntil retries and gives up only at the deadline' {
        $script:n = 0
        Mock Send-Json { $script:n++; if ($script:n -lt 3) { throw 'down' } }
        Send-InventoryUntil @{ a = 1 } ((Get-Date).AddMinutes(1)) | Should -BeTrue
        Mock Send-Json { throw 'down' }
        Send-InventoryUntil @{ a = 1 } ((Get-Date).AddSeconds(1)) | Should -BeFalse
    }
    It 'Receive-File resumes with Range after a lost connection' {
        $bytes = [byte[]](1..250) * 40   # 10000 bytes
        $bytes = [byte[]]($bytes[0..9999])
        $path = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-dl-' + [guid]::NewGuid())
        $script:froms = New-Object System.Collections.Generic.List[long]
        Mock Open-HttpStream {
            $script:froms.Add($From)
            if ($script:froms.Count -eq 1) { return @{ Stream = (New-Object FailingStream($bytes, 6000)); Response = $null; Resumed = $false } }
            return @{ Stream = (New-Object IO.MemoryStream(, [byte[]]($bytes[[int]$From..9999]))); Response = $null; Resumed = $true }
        }
        try {
            Receive-File 'http://x/payload.zip' $path 10000 ((Get-Date).AddMinutes(1)) | Should -BeTrue
            $script:froms[0] | Should -Be 0
            $script:froms[1] | Should -Be 6000
            [IO.File]::ReadAllBytes($path) | Should -Be $bytes
        } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    It 'Receive-File restarts when the host ignores Range, and gives up at the deadline' {
        $bytes = [byte[]]((1..250) * 40)
        $path = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-dl-' + [guid]::NewGuid())
        $script:calls = 0
        Mock Open-HttpStream {
            $script:calls++
            if ($script:calls -eq 1) { return @{ Stream = (New-Object FailingStream($bytes, 4000)); Response = $null; Resumed = $false } }
            return @{ Stream = (New-Object IO.MemoryStream(, $bytes)); Response = $null; Resumed = $false }
        }
        try {
            Receive-File 'http://x/payload.zip' $path 10000 ((Get-Date).AddMinutes(1)) | Should -BeTrue
            (Get-Item $path).Length | Should -Be 10000
        } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        Mock Open-HttpStream { throw 'host down' }
        $p2 = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-dl-' + [guid]::NewGuid())
        Receive-File 'http://x/payload.zip' $p2 10000 ((Get-Date).AddSeconds(1)) | Should -BeFalse
    }

    It 'shows on the console when the server is lost and found again, once each, and the remaining minutes' {
        $script:con = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $script:con.Add([string]$Object) }
        $script:calls = 0
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -le 3) { throw 'connection refused' }
            if ($script:calls -eq 4) { return [pscustomobject]@{ state = 'unknown' } }
            if ($script:calls -eq 5) { return [pscustomobject]@{ state = 'wait' } }
            [pscustomobject]@{ state = 'approved'; machine = $script:Opt.MachineId; disk = 0; serial = 'S' }
        }
        Mock Send-Json { }
        $r = Wait-Approval @{ machine = 'x' } ((Get-Date).AddMinutes(57))
        $r.state | Should -Be 'approved'
        @($script:con | Where-Object { $_ -match '^\d\d:\d\d:\d\d WARNING \(\S+\) server unreachable, retrying$' }).Count | Should -Be 1
        @($script:con | Where-Object { $_ -match ' INFO \(\S+\) server reachable again$' }).Count | Should -Be 1
        @($script:con | Where-Object { $_ -match 'server did not know this PC, inventory sent again$' }).Count | Should -Be 1
        @($script:con | Where-Object { $_ -match ' INFO \(\S+\) waiting for approval minutes_left=57$' }).Count | Should -Be 1
        @($script:con | Where-Object { $_ -like '*waiting for approval*' }).Count | Should -Be 1   # next one only after 5 minutes
    }
    It 'Send-InventoryUntil says once that the server is lost and when the inventory got through' {
        $script:con = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $script:con.Add([string]$Object) }
        $script:n = 0
        Mock Send-Json { $script:n++; if ($script:n -lt 4) { throw 'down' } }
        Send-InventoryUntil @{ a = 1 } ((Get-Date).AddMinutes(1)) | Should -BeTrue
        @($script:con | Where-Object { $_ -like '*server unreachable, retrying' }).Count | Should -Be 1
        $script:con[-1] | Should -Match ' INFO \(\S+\) server reachable again, inventory sent$'
    }
}

Describe 'Log format, busy server and elevation' {
    BeforeAll {
        function global:Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType, $TimeoutSec) }
        function global:Start-Process { param($FilePath, $Verb, $ArgumentList) }
    }
    BeforeEach {
        Mock Start-Sleep { }
        $script:LogFile = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-test-log-' + [guid]::NewGuid() + '.txt')
        $script:Opt.Server = 'http://127.0.0.1:8000'
        $script:Opt.MachineId = ''
    }
    AfterEach { Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue; $env:UNITOTEM_ELEVATED = $null }

    It 'log lines are "date time LEVEL (host) message", console with time only' {
        $env:COMPUTERNAME = 'DESKTOP-HM6RMUF'
        Format-LogLine 'WARNING' 'disk=0 serial=X' | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d WARNING \(DESKTOP-HM6RMUF\) disk=0 serial=X$'
        Format-LogLine 'INFO' 'm' 'HH:mm:ss' | Should -Match '^\d\d:\d\d:\d\d INFO \(DESKTOP-HM6RMUF\) m$'
    }
    It 'Say writes the console line and the log file line with the same level' {
        $env:COMPUTERNAME = 'PC-1'
        Mock Write-Host { }
        Say 'step=copy' 'ERROR' -Local
        Get-Content $script:LogFile | Should -Match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ERROR \(PC-1\) step=copy$'
    }
    It 'Test-BusyError recognises HTTP 409 without comparing text' {
        $resp = [pscustomobject]@{ StatusCode = 409 }
        $ex = New-Object System.Exception('anything in any language')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
        $er = New-Object System.Management.Automation.ErrorRecord($ex, 'x', 'NotSpecified', $null)
        Test-BusyError $er | Should -BeTrue
        $resp.StatusCode = 500
        Test-BusyError $er | Should -BeFalse
        Test-BusyError (New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception('plain')), 'x', 'NotSpecified', $null)) | Should -BeFalse
    }
    It 'a 409 on the inventory ends with the Busy exit code and no change' {
        $ex = New-Object System.Exception('409')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 409 })
        Mock Send-Json { throw $ex }
        Mock Write-Host { }
        $script:Opt.Remote = $true
        try {
            { Send-InventoryUntil @{ a = 1 } ((Get-Date).AddMinutes(1)) } | Should -Throw ('UNITOTEM_EXIT:' + $Script:Exit.Busy)
        } finally { $script:Opt.Remote = $false }
        $Script:Exit.Busy | Should -Be 10
    }
    It 'not elevated: starts an elevated PowerShell with the bootstrap command and returns' {
        Mock Start-Process { }
        Mock Write-Host { }
        Start-Elevated
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $Verb -eq 'RunAs' -and $FilePath -eq 'powershell.exe' -and
            ($ArgumentList -join ' ') -eq '-NoProfile -NoExit -Command "$env:UNITOTEM_ELEVATED=1; irm http://127.0.0.1:8000|iex"'
        }
    }
    It 'a refused elevation ends with the NotAdmin exit code' {
        Mock Start-Process { throw 'cancelled by the user' }
        Mock Write-Host { }
        $script:Opt.Remote = $true
        try { { Start-Elevated } | Should -Throw ('UNITOTEM_EXIT:' + $Script:Exit.NotAdmin) } finally { $script:Opt.Remote = $false }
    }
    It 'no second relaunch from an already relaunched process' {
        $env:UNITOTEM_ELEVATED = '1'
        Mock Start-Process { }
        Mock Write-Host { }
        $script:Opt.Remote = $true
        try { { Start-Elevated } | Should -Throw ('UNITOTEM_EXIT:' + $Script:Exit.NotAdmin) } finally { $script:Opt.Remote = $false }
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'GRUB4DOS boot entry, files and undo' {
    BeforeAll {
        function global:Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType, $TimeoutSec) }
        $script:pd = Join-Path ([IO.Path]::GetTempPath()) ('unitotem-g4d-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:pd | Out-Null
        $script:sums = @{}
        foreach ($n in 'vmlinuz', 'initrd.img', 'grldr', 'grldr.mbr') {
            [IO.File]::WriteAllBytes((Join-Path $script:pd $n), [Text.Encoding]::ASCII.GetBytes('payload ' + $n))
            $script:sums[$n] = (Get-FileHash (Join-Path $script:pd $n) -Algorithm SHA256).Hash.ToLower()
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:pd -Recurse -Force }
    BeforeEach {
        Mock Start-Sleep { }
        Mock Write-Host { }
        $script:LogFile = Join-Path $script:pd 'log.txt'
        $script:root = Join-Path $script:pd ('root-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:root | Out-Null
    }

    It 'the BCD entry is a bootsector application with device partition=C: and path \grldr.mbr' {
        $script:calls = New-Object System.Collections.Generic.List[string]
        Mock Invoke-Native { $script:calls.Add($Arguments -join ' '); if ($Arguments[0] -eq '/create') { return , @('The entry was successfully created: {0A1B2C3D-1111-2222-3333-444455556666}.') }; return , @() }
        $g = New-BcdBootsector 'C'
        $g | Should -Be '{0A1B2C3D-1111-2222-3333-444455556666}'
        $script:calls[0] | Should -Be '/create /d UniTotem OTA /application bootsector'
        $script:calls | Should -Contain '/set {0A1B2C3D-1111-2222-3333-444455556666} device partition=C:'
        $script:calls | Should -Contain ('/set {0A1B2C3D-1111-2222-3333-444455556666} path \grldr.mbr')
        $script:calls | Should -Contain '/displayorder {0A1B2C3D-1111-2222-3333-444455556666} /addlast'
        $script:calls | Should -Contain '/bootsequence {0A1B2C3D-1111-2222-3333-444455556666}'
        ($script:calls -join "`n") | Should -Not -Match 'g2'
    }
    It 'copies grldr.mbr, grldr, menu.lst, kernel and initrd, verified, and records them' {
        $menu = "default 0`ntitle UniTotem OTA`n"
        $kdir = Join-Path $script:root 'unitotem'
        $files = Install-GrubFourDosFiles $script:pd $script:sums ($script:root + [IO.Path]::DirectorySeparatorChar) $kdir $menu
        $files.Count | Should -Be 5
        foreach ($n in 'grldr.mbr', 'grldr', 'menu.lst') { Test-Path (Join-Path $script:root $n) | Should -BeTrue }
        foreach ($n in 'vmlinuz', 'initrd.img') { Test-Path (Join-Path $kdir $n) | Should -BeTrue }
        [IO.File]::ReadAllText((Join-Path $script:root 'menu.lst')) | Should -Be $menu
        foreach ($f in $files) { (Get-FileHash $f.Path -Algorithm SHA256).Hash.ToLower() | Should -Be $f.Sha256 }
    }
    It 'refuses to overwrite a menu.lst that is not ours' {
        Set-Content (Join-Path $script:root 'menu.lst') 'title Someone else' 
        $script:Opt.Remote = $true
        try {
            { Install-GrubFourDosFiles $script:pd $script:sums ($script:root + [IO.Path]::DirectorySeparatorChar) (Join-Path $script:root 'unitotem') "default 0`n" } | Should -Throw ('UNITOTEM_EXIT:' + $Script:Exit.Unsupported)
        } finally { $script:Opt.Remote = $false }
        Test-Path (Join-Path $script:root 'grldr') | Should -BeFalse
        Get-Content (Join-Path $script:root 'menu.lst') | Should -Be 'title Someone else'
    }
    It 'undo removes only our files and keeps a changed one' {
        $kdir = Join-Path $script:root 'unitotem'
        $files = Install-GrubFourDosFiles $script:pd $script:sums ($script:root + [IO.Path]::DirectorySeparatorChar) $kdir "default 0`n"
        Set-Content (Join-Path $script:root 'other.txt') 'user file'
        Set-Content (Join-Path $kdir 'user-note.txt') 'user file in the folder'
        Set-Content (Join-Path $script:root 'menu.lst') 'edited by someone'
        Remove-OurFiles $files '.*'
        foreach ($n in 'grldr.mbr', 'grldr') { Test-Path (Join-Path $script:root $n) | Should -BeFalse }
        foreach ($n in 'vmlinuz', 'initrd.img') { Test-Path (Join-Path $kdir $n) | Should -BeFalse }
        Test-Path (Join-Path $script:root 'menu.lst') | Should -BeTrue
        Test-Path (Join-Path $script:root 'other.txt') | Should -BeTrue
        Test-Path (Join-Path $kdir 'user-note.txt') | Should -BeTrue
        Test-Path $kdir | Should -BeTrue   # not empty: kept
    }
    It 'undo drops the empty unitotem folder and rejects unexpected paths' {
        $kdir = Join-Path $script:root 'unitotem'
        $files = Install-GrubFourDosFiles $script:pd $script:sums ($script:root + [IO.Path]::DirectorySeparatorChar) $kdir "default 0`n"
        Remove-OurFiles $files '.*'
        Test-Path $kdir | Should -BeFalse
        Set-Content (Join-Path $script:root 'victim.txt') 'x'
        Remove-OurFiles @(@{ Path = (Join-Path $script:root 'victim.txt'); Sha256 = (Get-FileHash (Join-Path $script:root 'victim.txt') -Algorithm SHA256).Hash.ToLower() }) 
        Test-Path (Join-Path $script:root 'victim.txt') | Should -BeTrue   # default pattern allows only grldr.mbr, grldr, menu.lst, unitotem\vmlinuz|initrd.img
    }
    It 'the default undo pattern matches the files we create and nothing else' {
        foreach ($p in 'C:\grldr.mbr', 'C:\grldr', 'C:\menu.lst', 'D:\unitotem\vmlinuz', 'D:\unitotem\initrd.img') { Test-FullMatch $p $Script:UndoPath | Should -BeTrue }
        foreach ($p in 'C:\Windows\System32\config', 'C:\boot.ini', 'C:\unitotem\..\x', 'C:\grldr.bak', 'C:\unitotem') { Test-FullMatch $p $Script:UndoPath | Should -BeFalse }
    }
    It 'finds BCD entries by description without reading localized labels' {
        $text = "Gestore di avvio\r\n-------\r\nidentificatore {bootmgr}\r\n\r\nApplicazione\r\n---\r\nidentificatore {0a1b2c3d-1111-2222-3333-444455556666}\r\ndescrizione UniTotem OTA\r\n\r\nWindows 10\r\nidentificatore {7e0a0a0a-1111-2222-3333-444455556666}\r\ndescrizione Windows 10"
        Mock Invoke-Native { , ($text -split "`n") }
        @(Find-OtaBcdEntries) | Should -Be @('{0a1b2c3d-1111-2222-3333-444455556666}')
    }
    It 'plan and facts name the boot method' {
        ((Build-Plan @{ Undo = $false; Mode = 'bios'; Where = 'cdrive'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n") | Should -Match 'boot-method=grub4dos loader=grldr.mbr,grldr,menu.lst'
    }
}
