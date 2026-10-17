# Admit the declared managed native x64 PortableGit fixture tools.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64' -or $env:RUNNER_ARCH -ne 'X64') { throw 'This role requires a native Windows x64 runner' }
$git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
if ([IO.Path]::GetFullPath($git) -ine 'C:\PortableGit\bin\git.exe') { throw 'Unrecognized managed native Git layout' }
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AcpNativeFixtureIdentity {
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
$receipt = [ordered]@{scope='Declared native Windows x64 PortableGit fixture role'; workflowSHA=$env:GITHUB_SHA; archivePin='4f3f21f4effcb659566883ee1ed3ae403e5b3d7a0699cee455f6cd765e1ac39c'; measuredImageAuthority='Actual authenticated distribution witness at ACP987 job117220495423'; directories=@(); images=@(); admitted=$false; PATHChanged=$false}
function Identity($handle, [string]$expected, [bool]$directory) {
  $info = [AcpNativeFixtureIdentity+Info]::new()
  if (-not [AcpNativeFixtureIdentity]::GetFileInformationByHandle($handle,[ref]$info)) { throw 'Native file identity query failed' }
  $path = [Text.StringBuilder]::new(32768)
  $length = [AcpNativeFixtureIdentity]::GetFinalPathNameByHandleW($handle,$path,32768,0)
  if ($length -eq 0 -or $length -ge 32768) { throw 'Native final-path query failed' }
  $canonical = $path.ToString()
  if ($canonical.StartsWith('\\?\')) { $canonical = $canonical.Substring(4) }
  if ($canonical -ine $expected -or ($info.Attributes -band 0x400) -ne 0 -or ((($info.Attributes -band 0x10) -ne 0) -ne $directory)) { throw 'Native path identity, type, or reparse refusal' }
  return [ordered]@{path=$canonical; volume=$info.Volume; indexHigh=$info.IndexHigh; indexLow=$info.IndexLow; attributes=$info.Attributes; links=$info.Links; sizeHigh=$info.SizeHigh; sizeLow=$info.SizeLow; writeHigh=$info.Write.dwHighDateTime; writeLow=$info.Write.dwLowDateTime}
}
function Hold-Directory([string]$path) {
  $handle = [AcpNativeFixtureIdentity]::CreateFileW($path,0x80000000,1,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
  if ($handle.IsInvalid) { $handle.Dispose(); throw 'Could not hold declared managed directory' }
  $holds.Add($handle)
  return Identity $handle $path $true
}
function Hold-Image([string]$path, [string]$expected, [long]$limit, [bool]$pe) {
  $item = Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Image type or reparse refusal' }
  $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $holds.Add($stream)
  if ($stream.Length -le 0 -or $stream.Length -gt $limit) { throw 'Declared image size bound refused' }
  $before = Identity $stream.SafeFileHandle $path $false
  if ($pe) {
    $reader = [IO.BinaryReader]::new($stream,[Text.Encoding]::ASCII,$true)
    try {
      if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Missing native PE header' }
      $stream.Position = 0x3c; $offset = $reader.ReadUInt32()
      if ($offset -gt $stream.Length - 6) { throw 'Invalid native PE offset' }
      $stream.Position = $offset
      if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Image is not native AMD64 PE' }
    } finally { $reader.Dispose() }
  }
  $stream.Position = 0
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
  $after = Identity $stream.SafeFileHandle $path $false
  if ($hash -cne $expected -or (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress))) { throw 'Declared image hash or held identity drift' }
  return [ordered]@{nativeIdentity=$before; sha256=$hash}
}
try {
  foreach ($path in @('C:\PortableGit','C:\PortableGit\bin','C:\PortableGit\usr','C:\PortableGit\usr\bin')) { $receipt.directories += Hold-Directory $path }
  $receipt.archive = Hold-Image 'C:\actions-runner-cache\PortableGit-2.47.1-64-bit.7z.exe' $receipt.archivePin 134217728 $false
  $images = [ordered]@{
    'bin/git.exe'='f668c4ba88417ecdf29470b3af92d576a701cc0f76dd083b13d032f4b3f1f247'
    'bin/bash.exe'='e5c6faaffbcfd51751f168a0e447d065deb1165e4420d0f7649fc0b6cfc046b4'
    'usr/bin/bash.exe'='fc362aae1f217d34d02237d99527839dd6cf85b37c7a0277109400bfa0faa594'
    'usr/bin/cat.exe'='f1b37048ee5c70fdc31dde509e562261c9b2d102d94c903393f55b45e883ef90'
    'usr/bin/sleep.exe'='3dfa2435317339e861121c1bd22e57b7b67c204705f00a88b5ac10a0cba87514'
    'usr/bin/msys-2.0.dll'='6803e2ae189007eca3341bb929ff4787da7eb02d0a5138377863d63a9a53b4a4'
  }
  foreach ($entry in $images.GetEnumerator()) { $receipt.images += Hold-Image ('C:\PortableGit\'+$entry.Key.Replace('/','\')) $entry.Value 67108864 $true }
  $env:PATH = 'C:\PortableGit\bin;C:\PortableGit\usr\bin;'+$env:PATH
  $receipt.processPATHChanged = $true
  foreach ($entry in @{git='C:\PortableGit\bin\git.exe';bash='C:\PortableGit\bin\bash.exe';cat='C:\PortableGit\usr\bin\cat.exe';sleep='C:\PortableGit\usr\bin\sleep.exe'}.GetEnumerator()) {
    $selected = (Get-Command $entry.Key -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ($selected -ine $entry.Value) { throw 'Declared native tool resolution refused' }
  }
  # GitHub prepends the last appended directory first; retain the existing bin frontends.
  [IO.File]::AppendAllText($env:GITHUB_PATH,"C:\PortableGit\usr\bin`nC:\PortableGit\bin`n",[Text.UTF8Encoding]::new($false))
  $receipt.PATHChanged = $true; $receipt.admitted = $true
} catch {
  $receipt.error = $_.Exception.Message
  throw
} finally {
  $receipt.identityScope = 'Admission-time held native identities; archive pin and observed distribution image hashes. No independent exhaustive DLL-closure or continuing-handle claim.'
  $receipt | ConvertTo-Json -Depth 12
  foreach ($hold in $holds) { $hold.Dispose() }
}
exit 0
