# UniTotem Windows probe (read-only): prints "KEY: value" lines, like do_probe() in deploy/remote-deploy.sh.
# PowerShell 5.1, run as Administrator.  Changes nothing (the ESP is mounted read-only-in-practice on a temp letter
# only if -MountEsp is given, and unmounted again).
#   powershell -ep bypass -File probe-windows.ps1 [-MountEsp]
param([switch]$MountEsp)
$ErrorActionPreference = 'Continue'
function KV($k,$v){ "{0}: {1}" -f $k,$v }

# --- architecture / firmware type (PEFirmwareType 1=BIOS 2=UEFI)
KV 'UNAME_M' ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
# NB: HKLM\SYSTEM\CurrentControlSet\Control\PEFirmwareType exists only in WinPE (verified in the lab: absent on Windows 11).
# Locale-independent: the loader path of the running OS is winload.efi on UEFI, winload.exe on BIOS.
$cur = (bcdedit /enum '{current}' | Out-String)
$efi = if($cur -match 'winload\.efi'){1}elseif($cur -match 'winload\.exe'){0}else{'unknown'}
KV 'EFI' $efi
KV 'OS' ((Get-CimInstance Win32_OperatingSystem | % { $_.Caption + ' ' + $_.Version + ' ' + $_.OSLanguage }))

# --- Secure Boot
$sb = 'unknown'; try { $sb = if(Confirm-SecureBootUEFI){1}else{0} } catch { $sb = 'unknown (' + $_.Exception.Message + ')' }
KV 'SECUREBOOT' $sb

function Parse-SigList([byte[]]$b){
  $x509 = [Guid]'a5c059a1-94e4-4aa7-87b5-ab155c2bf072'; $sha = [Guid]'c1c41626-504c-4092-aca9-41f936934328'
  $o = 0; $out = @()
  while($o + 28 -le $b.Length){
    $t = [Guid]::new([byte[]]$b[$o..($o+15)]); $ls = [BitConverter]::ToUInt32($b,$o+16); $hs = [BitConverter]::ToUInt32($b,$o+20); $ss = [BitConverter]::ToUInt32($b,$o+24)
    if($ls -lt 28 -or $o + $ls -gt $b.Length){ break }
    $p = $o + 28 + $hs
    while($p + $ss -le $o + $ls){
      $d = [byte[]]$b[($p+16)..($p+$ss-1)]
      if($t -eq $x509){ try { $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$d); $out += "x509 subject=[$($c.Subject)] notAfter=$($c.NotAfter.ToString('yyyy-MM-dd'))" } catch { $out += "x509 (unparseable)" } }
      elseif($t -eq $sha){ $out += 'sha256 ' + (($d | % { $_.ToString('x2') }) -join '') }
      else { $out += "other-type $t" }
      $p += $ss
    }
    $o += $ls
  }
  $out
}
$dbSubjects = @()
foreach($n in 'PK','KEK','db','dbx'){
  try {
    $v = Get-SecureBootUEFI -Name $n
    $e = Parse-SigList $v.Bytes
    KV "SB_VAR_$n" "$($v.Bytes.Length) bytes, $($e.Count) entries"
    if($n -ne 'dbx'){ $e | % { "  $n  $_" } } else { "  dbx  (sha256 entries: $(@($e | ? { $_ -like 'sha256*' }).Count), x509: $(@($e | ? { $_ -like 'x509*' }).Count))" }
    if($n -eq 'db'){ $dbSubjects = $e }
  } catch { KV "SB_VAR_$n" ('error: ' + $_.Exception.Message) }
}
KV 'SB_SETUPMODE' $(try { (Get-SecureBootUEFI -Name SetupMode).Bytes[0] } catch { 'unknown' })
$has2011 = [bool]($dbSubjects | ? { $_ -match 'Microsoft Corporation UEFI CA 2011' })
$has2023 = [bool]($dbSubjects | ? { $_ -match 'Microsoft UEFI CA 2023' })
KV 'SB_3RDPARTY_CA' $(if($has2011 -and $has2023){'both'}elseif($has2011){'2011'}elseif($has2023){'2023'}elseif($dbSubjects.Count){'none'}else{'unknown'})
KV 'SB_WINDOWS_CA_2023' ([bool]($dbSubjects | ? { $_ -match 'Windows UEFI CA 2023' }))

# --- BitLocker
try { Get-BitLockerVolume | % { KV ('BITLOCKER_' + $_.MountPoint) ("$($_.VolumeStatus) protection=$($_.ProtectionStatus) method=$($_.EncryptionMethod) protectors=" + (($_.KeyProtector | % { $_.KeyProtectorType }) -join ',')) } } catch { KV 'BITLOCKER' ('error: ' + $_.Exception.Message) }

# --- disks / partitions / ESP
Get-Disk | % { KV ('DISK_' + $_.Number) ("{0} bytes|{1}|{2}|{3}|serial={4}|boot={5}|system={6}|{7}" -f $_.Size,$_.BusType,$_.PartitionStyle,$_.FriendlyName.Trim(),("$($_.SerialNumber)").Trim(),$_.IsBoot,$_.IsSystem,$_.OperationalStatus) }
Get-Partition | % { KV ("PART_{0}_{1}" -f $_.DiskNumber,$_.PartitionNumber) ("{0} bytes|{1}|letter={2}|guid={3}" -f $_.Size,$_.Type,$_.DriveLetter,$_.GptType) }
$esp = Get-Partition | ? { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
if($esp){
  KV 'ESP' ("disk {0} part {1}, {2} bytes" -f $esp.DiskNumber,$esp.PartitionNumber,$esp.Size)
  if($MountEsp){
    $letter = $null; foreach($l in 'S','T','U','V','W'){ if(-not (Test-Path ($l+':\'))){ $letter = $l; break } }
    if($letter){
      $null = mountvol "${letter}:" /S
      try {
        $di = New-Object IO.DriveInfo ($letter + ':')
        KV 'BOOTFREE' ("{0} bytes free of {1} (fs {2}, label '{3}')" -f $di.AvailableFreeSpace,$di.TotalSize,$di.DriveFormat,$di.VolumeLabel)
        Get-ChildItem "${letter}:\EFI" -Directory | % { KV 'ESP_DIR' $_.Name }
      } finally { $null = mountvol "${letter}:" /D }
    }
  }
}
$c = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
if($c){ KV 'C_FREE' ("{0} bytes free of {1} ({2})" -f $c.SizeRemaining,$c.Size,$c.FileSystem) }

# --- network / RAM / power
Get-NetAdapter | % { KV ('NIC_' + $_.Name) ("{0}|{1}|mac={2}|media={3}|{4}" -f $_.InterfaceDescription,$_.Status,$_.MacAddress,$_.PhysicalMediaType,$_.LinkSpeed) }
Get-NetIPConfiguration | % { KV ('IP_' + $_.InterfaceAlias) ((($_.IPv4Address | % { $_.IPAddress }) -join ',') + ' gw=' + (($_.IPv4DefaultGateway | % { $_.NextHop }) -join ',') + ' dhcp=' + ((Get-NetIPInterface -InterfaceAlias $_.InterfaceAlias -AddressFamily IPv4).Dhcp)) }
$os = Get-CimInstance Win32_OperatingSystem
KV 'MEMTOTAL' ("{0} MB" -f [int]($os.TotalVisibleMemorySize/1024))
KV 'MEMAVAIL' ("{0} MB" -f [int]($os.FreePhysicalMemory/1024))
KV 'BATTERY' $(if(Get-CimInstance Win32_Battery){ 'present' } else { 'none' })
KV 'FASTSTARTUP' ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled)
KV 'HAVE_UNITOTEM' 0
