# Read/write raw UEFI variables from Windows (lab helper), run as Administrator.
#   .\nvram-var.ps1 -Name BootOrder [-Guid {..}] [-SetHex 0300..|-SetFile f.bin] [-Attr 7]   (Attr: 1=NV 2=BS 4=RT)
#   .\nvram-var.ps1 -Boot      decode BootCurrent/BootNext/BootOrder/Boot####
#
param([string]$Name='BootOrder',[string]$Guid='{8be4df61-93ca-11d2-aa0d-00e098032b8c}',[string]$SetHex,[string]$SetFile,[int]$Attr=7,[switch]$Boot)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Fw {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern uint GetFirmwareEnvironmentVariableA(string n,string g,byte[] b,uint s);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetFirmwareEnvironmentVariableExA(string n,string g,byte[] b,uint s,uint a);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h,uint a,out IntPtr t);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool LookupPrivilegeValue(string s,string n,out long l);
 [DllImport("advapi32.dll",SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref TP n,uint l,IntPtr p,IntPtr r);
 [StructLayout(LayoutKind.Sequential,Pack=1)] public struct TP { public uint Count; public long Luid; public uint Attr; }
 public static void Priv(){ IntPtr t; OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle,0x28,out t); TP p=new TP(); p.Count=1; p.Attr=2; LookupPrivilegeValue(null,"SeSystemEnvironmentPrivilege",out p.Luid); AdjustTokenPrivileges(t,false,ref p,0,IntPtr.Zero,IntPtr.Zero);}
}
"@
[Fw]::Priv()
if($SetFile){ $b=[IO.File]::ReadAllBytes($SetFile); "set: " + [Fw]::SetFirmwareEnvironmentVariableExA($Name,$Guid,$b,$b.Length,$Attr) }
if($SetHex){ $b=[byte[]]($SetHex -split '(..)' | ?{$_} | %{[Convert]::ToByte($_,16)}); "set: " + [Fw]::SetFirmwareEnvironmentVariableExA($Name,$Guid,$b,$b.Length,$Attr) }
$buf=New-Object byte[] 4096; $n=[Fw]::GetFirmwareEnvironmentVariableA($Name,$Guid,$buf,4096)
if($Boot){} elseif($n -eq 0){ "$Name : absent/err " + [Runtime.InteropServices.Marshal]::GetLastWin32Error() } else { "$Name : " + (($buf[0..($n-1)] | %{$_.ToString('x2')}) -join '') }

if($Boot){
  # decode the firmware boot variables: BootCurrent, BootNext, BootOrder and every Boot#### (EFI_LOAD_OPTION)
  function RdVar($n){ $b=New-Object byte[] 8192; $k=[Fw]::GetFirmwareEnvironmentVariableA($n,'{8be4df61-93ca-11d2-aa0d-00e098032b8c}',$b,8192); if($k -eq 0){return $null}; ,[byte[]]$b[0..($k-1)] }
  foreach($n in 'BootCurrent','BootNext'){ $v=RdVar $n; "{0} : {1}" -f $n,$(if($v){'{0:X4}' -f [BitConverter]::ToUInt16($v,0)}else{'(not set)'}) }
  $o=RdVar 'BootOrder'; $ids=@(); for($i=0;$i -lt $o.Length;$i+=2){ $ids+=[BitConverter]::ToUInt16($o,$i) }
  "BootOrder : " + (($ids | %{ '{0:X4}' -f $_ }) -join ' ')
  foreach($id in (0..0xFF)){ $v=RdVar ('Boot{0:X4}' -f $id); if(-not $v){continue}
    $len=[BitConverter]::ToUInt16($v,4); $e=6; while($v[$e] -or $v[$e+1]){$e+=2}
    $desc=[Text.Encoding]::Unicode.GetString($v,6,$e-6); $dp=$v[($e+2)..($e+1+$len)]
    $txt=[Text.Encoding]::Unicode.GetString($v,$e+2,[Math]::Max(0,$v.Length-$e-2)) -replace '[^\x20-\x7e]',''
    "Boot{0:X4} : attr={1:X} '{2}'  path-strings: {3}" -f $id,[BitConverter]::ToUInt32($v,0),$desc,$txt }
}
