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
        $b = Get-Content -Raw (Join-Path $PSScriptRoot 'grub-bios.cfg.template')
        (New-GrubCfg $b '') | Should -Not -Match '@'
    }
}
Describe 'Build-Plan' {
    It 'UEFI, boot partition: no shrink, no BitLocker action' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'uefi'; Where = 'boot'; NeededBytes = 240MB; PartBytes = 304MB; Token = 'QUJD' }) -join "`n"
        $p | Should -Match 'C: and BitLocker are not touched'
        $p | Should -Not -Match 'Shrink'
        $p | Should -Match 'Arm the OTA login'
    }
    It 'UEFI, new partition: shrink and BitLocker only on the new partition' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'uefi'; Where = 'new'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n"
        $p | Should -Match 'Shrink C: by 304 MiB'
        $p | Should -Match 'BitLocker off on it only'
        $p | Should -Match 'open mode'
        $p | Should -Not -Match 'Decrypt C'
    }
    It 'BIOS plan' {
        $p = (Build-Plan @{ Undo = $false; Mode = 'bios'; Where = 'boot'; NeededBytes = 240MB; PartBytes = 304MB; Token = $null }) -join "`n"
        $p | Should -Match 'unitotem-g2\.img'
        $p | Should -Not -Match 'Shrink'
    }
    It 'Undo plans' {
        ((Build-Plan @{ Undo = $true; Mode = 'bios' }) -join "`n") | Should -Match 'folder unitotem'
        ((Build-Plan @{ Undo = $true; Mode = 'uefi' }) -join "`n") | Should -Match 'EFI\\unitotem'
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
