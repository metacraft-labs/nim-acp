# Read-only witness. Does not alter PATH, extract archives, or grant tool admission.
$ErrorActionPreference = 'Stop'
$selectedGit = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$git = if ($null -eq $selectedGit) { '' } else { $selectedGit.Source }
$layoutMatches = $git -ne '' -and [IO.Path]::GetFullPath($git) -ieq 'C:\PortableGit\bin\git.exe'
$archive = 'C:\actions-runner-cache\PortableGit-2.47.1-64-bit.7z.exe'
$expectedArchive = '4f3f21f4effcb659566883ee1ed3ae403e5b3d7a0699cee455f6cd765e1ac39c'
function Observe-Image([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Image is a directory or reparse point' }
  $before = @($item.Length, $item.LastWriteTimeUtc.Ticks, $item.CreationTimeUtc.Ticks)
  $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
  finally { $stream.Dispose() }
  $item.Refresh(); $after = @($item.Length, $item.LastWriteTimeUtc.Ticks, $item.CreationTimeUtc.Ticks)
  if (($before -join ',') -ne ($after -join ',')) { throw 'Observed file metadata drift' }
  return @{path=$item.FullName; sha256=$hash; metadataBefore=$before; metadataAfter=$after; identityScope='Content and timestamps only; no file-ID or archive-member admission claim'}
}
$observations = [Collections.Generic.List[object]]::new()
function Observe-Optional([string]$Path) {
  try { return Observe-Image $Path }
  catch { $observations.Add(@{path=$Path; errorType=$_.Exception.GetType().FullName; error=$_.Exception.Message}); return $null }
}
$archiveRow = Observe-Optional $archive
$archiveMatches = $null -ne $archiveRow -and $archiveRow.sha256 -ceq $expectedArchive
$images = @{}
foreach ($name in @('git.exe','bash.exe')) { $images['bin/'+$name] = Observe-Optional ('C:\PortableGit\bin\'+$name) }
foreach ($name in @('bash.exe','cat.exe','sleep.exe','msys-2.0.dll')) { $images['usr/bin/'+$name] = Observe-Optional ('C:\PortableGit\usr\bin\'+$name) }
$resolution = @{}
foreach ($name in @('bash','cat','sleep')) {
  $selected = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $resolution[$name] = if ($null -eq $selected) { $null } else { $selected.Source }
}
@{scope='Read-only raw native x64 distribution witness; no tool admission';actualWorkflowSHA=$env:GITHUB_SHA; historicalFailureHead='30b012ff5f47c8e376713fe85a7f8c657710edef'; archive=$archiveRow; images=$images; currentApplicationResolution=$resolution; remaining='Exact archive member and runtime DLL closure comparison plus held native file identities before any role publication'; PATHChanged=$false; executedChildren=0; observedGit=$git; expectedNativeX64Layout=$layoutMatches; archiveMatchesDeclaredPin=$archiveMatches; independentObservationErrors=@($observations.ToArray()); rawWitnessComplete=($observations.Count -eq 0 -and $layoutMatches -and $archiveMatches)} | ConvertTo-Json -Depth 12

if ($observations.Count -ne 0 -or -not $layoutMatches -or -not $archiveMatches) { exit 1 }
exit 0
