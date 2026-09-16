$repo = 'UiPath/flow-workbench'
$runId = '35062181090'
$artifact = 'failed-tests'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
# The failed-tests artifact is far too big for a Maestro instance variable (60 KB on a bad night:
# 101 tests with multi-line errors), so the VM downloads it and prints one compact line. Each error
# keeps only its first line, 160 chars - exactly what selectTests' causeKey reads - and distinct
# lines are emitted once in 'e', with the per-test rows in 'r' indexing into it.
$h = @{ 'User-Agent' = 'vm-agent'; 'Accept' = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $h['Authorization'] = "token $($env:GH_TOKEN)" }
$errs = New-Object System.Collections.ArrayList
$seen = @{}
$rows = @()
try {
  $arts = Invoke-RestMethod -Headers $h -Uri "https://api.github.com/repos/$repo/actions/runs/$runId/artifacts?per_page=100"
  $a = $arts.artifacts | Where-Object { $_.name -eq $artifact } | Select-Object -First 1
  if (-not $a) { throw "run $runId has no '$artifact' artifact" }
  $zip = Join-Path $env:TEMP 'failed-tests.zip'
  $dir = Join-Path $env:TEMP 'failed-tests'
  Invoke-WebRequest -Headers $h -Uri $a.archive_download_url -OutFile $zip
  if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  $f = Get-ChildItem $dir -Recurse -Filter '*.json' | Select-Object -First 1
  if (-not $f) { throw "artifact '$artifact' holds no .json file" }
  # Assigned, not @()-wrapped: Windows PowerShell 5.1 hands ConvertFrom-Json's array to the
  # pipeline as one item, so @(...) yields a single element holding every row.
  $tests = Get-Content $f.FullName -Raw | ConvertFrom-Json
  foreach ($t in $tests) {
    $e = ''
    if ($t.error) { $e = @($t.error -split [char]10 | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0] }
    if ($null -eq $e) { $e = '' }
    if ($e.Length -gt 160) { $e = $e.Substring(0, 160) }
    if (-not $seen.ContainsKey($e)) { $seen[$e] = $errs.Add($e) }
    $rows += [pscustomobject]@{ p = $t.environment; f = $t.file; t = $t.title; i = $seen[$e] }
  }
} catch { Write-Output "[failures] $_" }
$json = [pscustomobject]@{ e = @($errs); r = @($rows) } | ConvertTo-Json -Compress -Depth 5
# vm-exec returns the last 32000 chars of stdout only, and non-ASCII survives the hop badly.
$json = [regex]::Replace($json, '[^ -~]', '?')
Write-Output "[failures] $($rows.Count) failed tests, $($errs.Count) distinct causes"
Write-Output "FAILED_JSON=$json"
exit 0
