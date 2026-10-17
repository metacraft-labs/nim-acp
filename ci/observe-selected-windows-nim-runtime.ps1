# Failure-only installed compiler source witness; never executes or changes tools.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64' -or $env:RUNNER_ARCH -ne 'X64') { throw 'Native Windows x64 witness only' }
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AcpRuntimeWitnessIdentity {
  [StructLayout(LayoutKind.Sequential)] public struct Info {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
}
'@

$holds = [Collections.Generic.List[IDisposable]]::new()
function Identity($handle, [string]$expected, [bool]$directory) {
  $info = [AcpRuntimeWitnessIdentity+Info]::new()
  if (-not [AcpRuntimeWitnessIdentity]::GetFileInformationByHandle($handle,[ref]$info)) { throw 'Native identity query failed' }
  $path = [Text.StringBuilder]::new(32768)
  $length = [AcpRuntimeWitnessIdentity]::GetFinalPathNameByHandleW($handle,$path,32768,0)
  if ($length -eq 0 -or $length -ge 32768) { throw 'Native final-path query failed' }
  $canonical = $path.ToString()
  if ($canonical.StartsWith('\\?\')) { $canonical = $canonical.Substring(4) }
  if ($canonical -ine $expected -or ($info.Attributes -band 0x400) -ne 0 -or ((($info.Attributes -band 0x10) -ne 0) -ne $directory)) { throw 'Native path/type/reparse mismatch' }
  return [ordered]@{path=$canonical; volume=$info.Volume; indexHigh=$info.IndexHigh; indexLow=$info.IndexLow; attributes=$info.Attributes; links=$info.Links; sizeHigh=$info.SizeHigh; sizeLow=$info.SizeLow; writeHigh=$info.Write.dwHighDateTime; writeLow=$info.Write.dwLowDateTime}
}
function Hold-Directory([string]$path) {
  $handle = [AcpRuntimeWitnessIdentity]::CreateFileW($path,[uint32]2147483648,1,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
  if ($handle.IsInvalid) { $handle.Dispose(); throw 'Directory hold refused' }
  $holds.Add($handle)
  return Identity $handle $path $true
}
function Read-Held([string]$path, [long]$limit, [bool]$content) {
  $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $holds.Add($stream)
  $before = Identity $stream.SafeFileHandle $path $false
  if ($stream.Length -le 0 -or $stream.Length -gt $limit) { throw 'Finite witness size refused' }
  $hash = [Security.Cryptography.SHA256]::Create()
  try { $digest = [Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant() } finally { $hash.Dispose() }
  $result = [ordered]@{identity=$before; sha256=$digest; bytes=$stream.Length}
  if ($content) {
    $stream.Position=0
    $bytes=[byte[]]::new([int]$stream.Length)
    $offset=0
    while ($offset -lt $bytes.Length) { $n=$stream.Read($bytes,$offset,$bytes.Length-$offset); if ($n -le 0) { throw 'Truncated held read' }; $offset+=$n }
    $result.contentBase64=[Convert]::ToBase64String($bytes)
  }
  $after=Identity $stream.SafeFileHandle $path $false
  if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { throw 'Held source drift' }
  return $result
}
try {
  $workspace=[IO.Path]::GetFullPath((Get-Location).Path)
  $profilePath=[IO.Path]::Combine($workspace,'.repro','build','repro','path-only-tool-identities.inspect.json')
  $profileWitness=Read-Held $profilePath 4194304 $true
  $profileText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($profileWitness.contentBase64))
  $profiles=@(($profileText | ConvertFrom-Json).profiles | Where-Object { $_.packageId -ceq 'nim' })
  if ($profiles.Count -ne 1) { throw 'Exactly one actual Nim role required' }
  $selected=$profiles[0]
  $raw=[string]$selected.resolvedExecutablePath
  if (-not [IO.Path]::IsPathFullyQualified($raw)) { throw 'Absolute selected compiler required' }
  $exe=[IO.Path]::GetFullPath($raw)
  if ($exe -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetFileName($exe) -ine 'nim.exe') { throw 'Local selected Nim executable required' }
  $bin=[IO.Path]::GetDirectoryName($exe)
  if ([IO.Path]::GetFileName($bin) -ine 'bin') { throw 'Selected compiler bin layout required' }
  $root=[IO.Path]::GetDirectoryName($bin)
  $directories=@()
  foreach ($relative in @('', 'bin', 'lib', 'lib\system', 'lib\system\mm', 'config')) {
    $path=if ($relative) { [IO.Path]::Combine($root,$relative) } else { $root }
    $directories+=Hold-Directory $path
  }
  $compiler=Read-Held $exe 134217728 $false
  $sources=@()
  foreach ($relative in @('lib\system\alloc.nim','lib\system\threads.nim','lib\system\threadlocalstorage.nim','lib\system\memalloc.nim','lib\system\seqs_v2.nim','lib\system\mm\arc.nim','lib\system\mm\orc.nim')) {
    $sources+=Read-Held ([IO.Path]::Combine($root,$relative)) 1048576 $true
  }
  $config=Read-Held ([IO.Path]::Combine($root,'config','nim.cfg')) 1048576 $false
  [ordered]@{scope='Post-failure selected installed Nim source observations; not execution-time byte identity or allocator cause'; workflowSHA=$env:GITHUB_SHA; profileSHA256=$profileWitness.sha256; rawSelectedExecutable=$raw; recordedExecutableDigest=[string]$selected.resolvedExecutableDigest; recordedProfileFingerprint=[string]$selected.profileFingerprint; digestComparison='Recorded profile digest and observed SHA256 are separate algorithms; no equality inferred'; directories=$directories; compiler=$compiler; sources=$sources; config=$config; toolsExecuted=$false; PATHChanged=$false} | ConvertTo-Json -Depth 12
} finally {
  for ($i=$holds.Count-1; $i -ge 0; $i--) { $holds[$i].Dispose() }
}
