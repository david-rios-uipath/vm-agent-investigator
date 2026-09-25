# Nightly CI history for one spec, ported from the flow's ciHistoryInstructions node.
# Returns a hashtable; writes the full failing job log next to it so it reaches the bucket.

# Studio shards are named `E2E (studio-alpha) [2/5]`, but a vsix job carries its runner platform
# inside the same parens: `E2E (vsix-alpha, Linux)`. Matching only `($project)` found no job for
# any vsix spec, so every one of them classified as `absent` and the investigator got no history.
# The trailing comma is what keeps `vsix-alpha` from also matching `vsix-alpha-cursor`.
function Test-CiJobForProject([string]$JobName, [string]$Project) {
  return ($JobName -like "*($Project)*") -or ($JobName -like "*($Project,*")
}

# `E2E (vsix-alpha, Linux)` -> `Linux`. Studio shards carry no platform (`E2E (studio-alpha) [2/5]`)
# and return ''. Which platforms agree matters: a spec red on Linux and green on macOS every night
# is a runner-environment failure, and merging the jobs into one verdict per night hides exactly
# that - the investigator then reasons about product code for a screen-size problem.
function Get-CiJobPlatform([string]$JobName) {
  $m = [regex]::Match($JobName, '\([^),]+,\s*([^)]+)\)')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Get-CiHistory([string]$RepoUrl, [string]$Branch, [string]$TestCommand, [string]$NotesDir) {
  $ErrorActionPreference = 'Continue'
  $r = [ordered]@{ classification = 'unknown'; summary = ''; firstFailSha = ''; lastPassSha = ''; runs = @(); ciFailureExcerpt = ''; ciJobLog = ''; ciTestResults = ''; target = ''; targetVerdict = 'absent' }

  # The GH_TOKEN asset may hold a placeholder; take the first token GitHub actually accepts.
  $token = $null
  foreach ($cand in @($env:GH_TOKEN)) {
    if (-not $cand) { continue }
    try { Invoke-RestMethod https://api.github.com/user -Headers @{ Authorization = "Bearer $cand"; 'User-Agent' = 'vm-agent' } | Out-Null; $token = $cand; break } catch { }
  }
  if (-not $token) { $r.summary = 'GH_TOKEN is not accepted by GitHub; CI history unavailable'; return $r }

  $m = [regex]::Match($RepoUrl, 'github\.com[/:]([^/]+)/([^/.]+)')
  if (-not $m.Success) { $r.summary = 'repository is not on github.com; CI history unavailable'; return $r }
  $owner = $m.Groups[1].Value; $repo = $m.Groups[2].Value

  $specPath = [regex]::Match($TestCommand, '([\w./-]+\.spec\.ts)').Groups[1].Value
  $project = [regex]::Match($TestCommand, '--project[= ]([\w-]+)').Groups[1].Value
  if (-not $specPath) { $r.summary = 'no *.spec.ts in the test command; CI history unavailable'; return $r }
  $spec = Split-Path $specPath -Leaf
  $grep = Get-TestTitle $TestCommand

  $h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'vm-agent' }
  $api = "https://api.github.com/repos/$owner/$repo"
  # ponytail: nightly workflow file is fixed; make it a flow input if a second repo ever uses this
  # The vsix projects run inside this same nightly, as jobs of the reusable playwright-vsix.yml.
  $workflow = 'playwright-ci.yml'
  # `branch=` intermittently serves a stale snapshot from this endpoint: runs from June to August
  # on 2026-09-16, nothing newer than 09-08 on the morning of 09-25, current again two hours
  # later. And since 2026-09-18 the nightly starts on `workflow_run` (after the 04:00 VSIX build),
  # not `schedule`. So: no `branch=`, one query per event, branch filtered here, and a staleness
  # warning below, since no query shape is proven immune.
  # A `skipped` run is a PR-label or manual VSIX build the workflow's own guard turned away; those
  # share the `workflow_run` page, hence 100 rather than 30, or nightlies fall off it over time.
  try {
    $all = @()
    foreach ($ev in 'workflow_run', 'schedule') {
      $all += @((Invoke-RestMethod "$api/actions/workflows/$workflow/runs?event=$ev&per_page=100" -Headers $h).workflow_runs)
    }
    $runs = @($all | Where-Object { $_.head_branch -eq $Branch -and $_.conclusion -ne 'skipped' } |
              Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 8)
  }
  catch { $r.summary = 'GitHub API error listing runs: ' + $_.Exception.Message; return $r }
  if (-not $runs -or $runs.Count -eq 0) { $r.summary = "no nightly $workflow runs on $Branch"; return $r }
  $stale = Get-CiStaleNote ([datetime]$runs[0].created_at) (Get-Date)

  $savedLog = $false
  $runSignals = @{}; $runExcerpts = @{}; $newestTargets = @()
  foreach ($run in $runs) {
    $isNewest = ($run.id -eq $runs[0].id)
    $sha = $run.head_sha.Substring(0, 7); $date = ([datetime]$run.created_at).ToUniversalTime().ToString('yyyy-MM-dd')
    $marks = @{}
    $platformMarks = @{}
    try { $jobs = (Invoke-RestMethod "$api/actions/runs/$($run.id)/jobs?per_page=100" -Headers $h).jobs } catch { $jobs = @() }
    $jobs = @($jobs | Where-Object { $_.name -like '*E2E*' })
    if ($project) { $jobs = @($jobs | Where-Object { Test-CiJobForProject $_.name $project }) }
    foreach ($job in $jobs) {
      $tmp = Join-Path $env:TEMP ('ci-' + $job.id + '.log')
      if (-not (Get-CiJobLog $job.id $tmp $api $h)) { continue }
      $m = Get-CiMarks ([System.IO.File]::ReadAllLines($tmp)) $spec $grep
      foreach ($k in $m.marks.Keys) { $marks[$k] = [string]$marks[$k] + $m.marks[$k] }
      $plat = Get-CiJobPlatform $job.name
      if ($plat) {
        if (-not $platformMarks.ContainsKey($plat)) { $platformMarks[$plat] = @{} }
        foreach ($k in $m.marks.Keys) { $platformMarks[$plat][$k] = [string]$platformMarks[$plat][$k] + $m.marks[$k] }
      }
      $sawFail = @($m.marks.Values | Where-Object { ([string]$_).Contains('F') }).Count -gt 0
      # One sequence per job: joined, Windows' `FFF` and Linux's `P` read as a flaky `FFFP`, and
      # run-phase then skipped a test that failed every attempt on one platform as a flake.
      if ($isNewest -and $m.target) { $newestTargets += $m.target }
      # Environment signals in every sampled night, not just the newest, so a shared-environment
      # pattern (identity 429, cleanup 400s, editor load failure) shows up as a trend.
      $clean = [System.IO.File]::ReadLines($tmp) | ForEach-Object { ($_ -replace '^\S+Z ?', '') -replace '\x1b\[[0-9;]*m', '' }
      $sig = [ordered]@{}
      foreach ($pair in @(
        @('identity429', 'autherror\?error=%20\(429\)|\(429\)|rate.?limit'),
        @('cleanup400', 'was not deleted, status 400'),
        @('editorLoad', 'activateFlowFile|failIfHostCouldNotLoadEditor|editor failed to load'),
        @('network', 'ECONNRESET|ETIMEDOUT|ENOTFOUND|socket hang up'))) {
        $c = @($clean | Select-String -Pattern $pair[1] -AllMatches).Count
        if ($c -gt 0) { $sig[$pair[0]] = $c }
      }
      if ($sig.Count -gt 0) { $runSignals[$sha] = $sig }
      if ($sawFail) {
        $sb = New-Object System.Text.StringBuilder; $in = $false
        $startRx = '^\s*\d+\)\s+\[[^\]]+\]\s+\S+\s+\S*' + [regex]::Escape($spec)
        foreach ($l in $clean) {
          if ($l -match $startRx) { $in = $true }
          elseif ($in -and ($l -match '^\s*\d+\)\s+\[' -or $l -match '^\s*\d+ (failed|flaky|passed|skipped|did not run)')) { $in = $false }
          if ($in) { [void]$sb.AppendLine($l); if ($sb.Length -gt 6000) { break } }
        }
        $excerpt = "CI job: $($job.name) ($($job.html_url))" + [Environment]::NewLine + $sb.ToString()
        if (-not $savedLog) {
          $savedLog = $true
          $r.ciJobLog = Join-Path $NotesDir 'ci-job.log'
          [System.IO.File]::WriteAllLines($r.ciJobLog, [string[]]$clean)
          $r.ciFailureExcerpt = $excerpt
          $r.ciTestResults = Save-CiTestResults $api $h $run.id $job.name $spec $grep $NotesDir
        } else {
          $runExcerpts[$sha] = $excerpt.Substring(0, [Math]::Min(800, $excerpt.Length))
        }
      }
      Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    $verdict = Get-CiVerdict @($marks.Values | ForEach-Object { [string]$_ })
    $row = [ordered]@{ date = $date; sha = $sha; verdict = $verdict; url = $run.html_url }
    if ($platformMarks.Count -gt 1) {
      $byPlatform = [ordered]@{}
      foreach ($plat in ($platformMarks.Keys | Sort-Object)) {
        $byPlatform[$plat] = Get-CiVerdict @($platformMarks[$plat].Values | ForEach-Object { [string]$_ })
      }
      # `absent` is missing data, not a differing verdict: counting it as disagreement made the
      # split fire on all 8 of 8 runs, and a signal that always fires is noise.
      $seen = @($byPlatform.Values | Where-Object { $_ -ne 'absent' } | Sort-Object -Unique)
      if ($seen.Count -gt 1) { $row.byPlatform = $byPlatform }
    }
    if ($runSignals.ContainsKey($sha)) { $row.envSignals = $runSignals[$sha] }
    if ($runExcerpts.ContainsKey($sha)) { $row.excerpt = $runExcerpts[$sha] }
    $r.runs += $row
  }

  $r.target = $grep
  if ($grep) { $r.targetVerdict = Get-CiVerdict $newestTargets }

  $obs = @($r.runs | Where-Object { $_.verdict -in 'failed', 'flaky', 'passed' })
  if ($obs.Count -eq 0) {
    $r.classification = 'absent'
    $r.summary = "$spec did not run in the last $($r.runs.Count) nightly runs of $workflow on $Branch$stale"
    return $r
  }
  $streak = 0; foreach ($o in $obs) { if ($o.verdict -eq 'failed') { $streak++ } else { break } }
  $rest = @($obs | Select-Object -Skip $streak)
  $hasFlaky = @($obs | Where-Object { $_.verdict -eq 'flaky' }).Count -gt 0
  $restHasFail = @($rest | Where-Object { $_.verdict -eq 'failed' }).Count -gt 0
  if ($streak -gt 0) { $r.firstFailSha = $obs[$streak - 1].sha }
  if ($rest.Count -gt 0) { $r.lastPassSha = @($rest | Where-Object { $_.verdict -ne 'failed' })[0].sha }
  if ($streak -eq $obs.Count) { $r.classification = 'consistent' }
  elseif ($streak -gt 0 -and -not $hasFlaky -and -not $restHasFail) { $r.classification = 'regression' }
  elseif ($streak -eq 0 -and -not $hasFlaky -and -not $restHasFail) { $r.classification = 'passing' }
  else { $r.classification = 'flaky' }

  $hist = ($r.runs | ForEach-Object {
    $line = "$($_.date) $($_.sha) $($_.verdict)"
    if ($_.byPlatform) { $line += ' (' + (($_.byPlatform.GetEnumerator() | ForEach-Object { $_.Key + ' ' + $_.Value }) -join ', ') + ')' }
    $line
  }) -join '; '
  $r.summary = "$($r.classification): $spec over the last $($r.runs.Count) nightly runs (newest first): $hist"
  if ($r.firstFailSha) { $r.summary += "; failing since $($r.firstFailSha)" }
  if ($r.lastPassSha) { $r.summary += "; last pass $($r.lastPassSha)" }
  if ($grep) { $r.summary += "; targeted test in the newest run: $($r.targetVerdict)" }
  # Spelled out rather than left for the reader to infer from the per-night parentheses: a spec
  # that fails on one platform and passes on another is about the runner, not the product.
  $split = @($r.runs | Where-Object { $_.byPlatform })
  if ($split.Count -gt 0) {
    $r.summary += "; PLATFORM SPLIT in $($split.Count) of $($r.runs.Count) runs - the same commit passes on some runners and fails on others, so suspect the runner environment (screen size, display server, OS paths) before the product"
  }
  $r.summary += $stale
  $sigRuns = @($r.runs | Where-Object { $_.envSignals })
  if ($sigRuns.Count -gt 0) {
    $r.summary += '; environment signals: ' + (($sigRuns | ForEach-Object { $_.sha + '=' + (($_.envSignals.GetEnumerator() | ForEach-Object { $_.Key + ':' + $_.Value }) -join ',') }) -join ' ')
  }
  return $r
}

# Pure: one job log -> per-test P/F/S sequences for the spec, plus the sequence of the one test
# the run targets (the --grep title), so a spec-level failure is never pinned on a test that
# ended green. Covered by vm/selfcheck.ps1.
function Get-CiMarks([string[]]$Lines, [string]$Spec, [string]$Grep) {
  # The list reporter drops to ASCII where the terminal cannot do Unicode, which on this nightly
  # means every Windows runner: `ok`/`x` instead of the Linux and macOS runners' checkmark and
  # ballot-X. Matching only the Unicode pair made every Windows job read as `absent` - the spec
  # looked like it had never run there, which is worse than no data because it reads as a
  # platform difference that is not real.
  $fail = [string][char]0x2718; $pass = [string][char]0x2713
  $rx = '^(?:\S+Z )?\s*(' + $fail + '|' + $pass + '|ok|x|-)\s+\d+\s+\[[^\]]+\]\s+\S+\s+(\S*' + [regex]::Escape($Spec) + ':\d+:\d+)(.*)$'
  $marks = @{}; $target = ''
  foreach ($line in $Lines) {
    $mm = [regex]::Match($line, $rx)
    if (-not $mm.Success) { continue }
    $mark = switch ($mm.Groups[1].Value) { $fail { 'F' } 'x' { 'F' } $pass { 'P' } 'ok' { 'P' } default { 'S' } }
    $k = $mm.Groups[2].Value
    $marks[$k] = [string]$marks[$k] + $mark
    if ($Grep -and $mm.Groups[3].Value -match [regex]::Escape($Grep)) { $target += $mark }
  }
  return @{ marks = $marks; target = $target }
}

# The nightly runs every day, so a newest run older than three days means GitHub answered with a
# stale listing (it has twice) and every verdict below compares against old code. Said in the
# summary rather than silently trusted. Covered by selfcheck.
function Get-CiStaleNote([datetime]$Newest, [datetime]$Now) {
  $days = [int][Math]::Floor(($Now.ToUniversalTime() - $Newest.ToUniversalTime()).TotalDays)
  if ($days -lt 3) { return '' }
  return "; STALE HISTORY: the newest nightly GitHub listed is from $($Newest.ToUniversalTime().ToString('yyyy-MM-dd')), $days days old - the run listing is likely stale, so do not trust these verdicts or the failing-since range"
}

# Playwright retries: 'FP' is a flaky test, 'F' a failed one, 'P' a pass.
function Get-CiVerdict([string[]]$Seqs) {
  if ($Seqs.Count -eq 0) { return 'absent' }
  if ($Seqs | Where-Object { $_.EndsWith('F') }) { return 'failed' }
  if ($Seqs | Where-Object { $_.EndsWith('P') -and $_.Contains('F') }) { return 'flaky' }
  if ($Seqs | Where-Object { $_.EndsWith('P') }) { return 'passed' }
  return 'skipped'
}

function Get-CiJobLog([string]$JobId, [string]$Path, [string]$Api, [hashtable]$Headers) {
  if (Save-GitHubDownload "$Api/actions/jobs/$JobId/logs" $Path $Headers) { return $true }
  Write-Output "[ci-history] could not fetch log for job $JobId"
  return $false
}

# Job logs and artifact zips both answer with a redirect to signed storage.
function Save-GitHubDownload([string]$Url, [string]$Path, [hashtable]$Headers) {
  try { Invoke-WebRequest $Url -Headers $Headers -UseBasicParsing -OutFile $Path; return $true } catch { }
  try { Invoke-WebRequest $Url -Headers $Headers -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop | Out-Null } catch {
    # Response is null for non-HTTP failures; indexing it would kill the whole phase.
    $resp = $_.Exception.Response
    $loc = if ($resp -and $resp.Headers) { $resp.Headers['Location'] } else { $null }
    if ($loc) { try { Invoke-WebRequest $loc -UseBasicParsing -OutFile $Path; return $true } catch { } }
  }
  return $false
}

# The failing job's name -> its `playwright-traces-*` artifact, mirroring the upload names in
# flow-workbench's playwright-vsix.yml and playwright-action.yml:
#   `e2e-vsix-alpha / E2E (vsix-alpha, Windows)` -> `playwright-traces-vsix-alpha-windows`
#   `e2e-studio / E2E (studio-alpha) [2/5]`      -> `playwright-traces-studio-alpha-2`
# The last parenthesised group, since the caller prefix could carry its own. Covered by selfcheck.
function Get-CiTracesArtifactName([string]$JobName) {
  $m = [regex]::Match($JobName, '\(([^()]+)\)\s*(?:\[(\d+)/\d+\])?\s*$')
  if (-not $m.Success) { return '' }
  $parts = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() })
  $name = 'playwright-traces-' + $parts[0]
  if ($parts.Count -gt 1) { $name += '-' + $parts[1].ToLower() }
  if ($m.Groups[2].Success) { $name += '-' + $m.Groups[2].Value }
  return $name
}

# Test-results folder names are truncated and hashed, so the `- Name:` line of error-context.md
# (`connectors\connectors.spec.ts >> <describe> >> <title>`) is what identifies the test.
# Covered by selfcheck.
function Test-ErrorContextFor([string]$Text, [string]$Spec, [string]$Grep) {
  $m = [regex]::Match($Text, '(?m)^- Name: (.+?)\s*$')
  if (-not $m.Success) { return $false }
  $name = $m.Groups[1].Value
  $file = @(($name -split ' >> ')[0] -split '[\\/]')[-1]
  if ($file -ne $Spec) { return $false }
  return (-not $Grep) -or ($name.IndexOf($Grep, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# The CI run's own Playwright artifacts for the failing test (error-context.md, trace, workbench
# screenshot). When CI settles the verdict the VM never re-runs the test, and these plus
# ci-job.log are the only evidence. The artifact is uploaded on failure only, so a missing one
# is normal. Returns the directory, or '' when nothing was saved. Logs with Write-Host: output
# here would land in the caller's return value.
function Save-CiTestResults([string]$Api, [hashtable]$Headers, $RunId, [string]$JobName, [string]$Spec, [string]$Grep, [string]$NotesDir) {
  $name = Get-CiTracesArtifactName $JobName
  if (-not $name) { return '' }
  try { $arts = @((Invoke-RestMethod "$Api/actions/runs/$RunId/artifacts?name=$name" -Headers $Headers).artifacts) } catch { $arts = @() }
  $a = @($arts | Where-Object { -not $_.expired }) | Select-Object -First 1
  if (-not $a) { Write-Host "[ci-history] run $RunId has no $name artifact"; return '' }
  # ponytail: whole-artifact download; a macOS leg reached 218 MB once. Past this, skip it.
  if ($a.size_in_bytes -gt 300MB) { Write-Host "[ci-history] $name is $([int]($a.size_in_bytes/1MB)) MB; not downloaded"; return '' }
  $zip = Join-Path $env:TEMP "$name.zip"
  $dir = Join-Path $env:TEMP $name
  if (-not (Save-GitHubDownload $a.archive_download_url $zip $Headers)) { Write-Host "[ci-history] could not download $name"; return '' }
  $dest = Join-Path $NotesDir 'ci-test-results'
  $kept = 0
  try {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    foreach ($ctx in @(Get-ChildItem $dir -Recurse -File -Filter 'error-context.md')) {
      if (-not (Test-ErrorContextFor ([System.IO.File]::ReadAllText($ctx.FullName)) $Spec $Grep)) { continue }
      $to = Join-Path $dest $ctx.Directory.Name
      New-Item -ItemType Directory -Force -Path $to | Out-Null
      # Same guard as the repro copy: the traces are what makes a folder big.
      $size = (Get-ChildItem $ctx.Directory.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
      if ($size -lt 25MB) { Copy-Item (Join-Path $ctx.Directory.FullName '*') $to -Recurse -Force }
      else { Copy-Item $ctx.FullName $to -Force }
      $kept++
    }
  } catch { Write-Host "[ci-history] could not unpack $($name): $($_.Exception.Message)" }
  finally { Remove-Item $zip, $dir -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host "[ci-history] kept $kept failing-test folder(s) from $name"
  if ($kept -eq 0) { return '' }
  return $dest
}

# CI history alone settles a deterministic or flaky verdict; anything else needs a local repro.
function Test-NeedsRepro($CiResult) {
  return -not (@('regression', 'consistent', 'flaky') -contains $CiResult.classification)
}
