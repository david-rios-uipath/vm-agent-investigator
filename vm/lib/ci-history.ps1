# Nightly CI history for one spec, ported from the flow's ciHistoryInstructions node.
# Returns a hashtable; writes the full failing job log next to it so it reaches the bucket.

function Get-CiHistory([string]$RepoUrl, [string]$Branch, [string]$TestCommand, [string]$NotesDir) {
  $ErrorActionPreference = 'Continue'
  $r = [ordered]@{ classification = 'unknown'; summary = ''; firstFailSha = ''; lastPassSha = ''; runs = @(); ciFailureExcerpt = ''; ciJobLog = ''; target = ''; targetVerdict = 'absent' }

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
  # The --grep title names the one test this run is about; the spec can fail on a different one.
  $gm = [regex]::Match($TestCommand, '--grep[= ]+(?:"([^"]*)"|''([^'']*)''|(\S+))')
  $grep = if ($gm.Success) { @($gm.Groups[1].Value, $gm.Groups[2].Value, $gm.Groups[3].Value | Where-Object { $_ })[0] } else { '' }

  $h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'vm-agent' }
  $api = "https://api.github.com/repos/$owner/$repo"
  # ponytail: nightly workflow file is fixed; make it a flow input if a second repo ever uses this
  try { $runs = (Invoke-RestMethod "$api/actions/workflows/playwright-ci.yml/runs?event=schedule&branch=$Branch&per_page=8" -Headers $h).workflow_runs }
  catch { $r.summary = 'GitHub API error listing runs: ' + $_.Exception.Message; return $r }

  $savedLog = $false
  $runSignals = @{}; $runExcerpts = @{}; $newestTarget = ''
  foreach ($run in $runs) {
    $isNewest = ($run.id -eq $runs[0].id)
    $sha = $run.head_sha.Substring(0, 7); $date = ([datetime]$run.created_at).ToUniversalTime().ToString('yyyy-MM-dd')
    $marks = @{}
    try { $jobs = (Invoke-RestMethod "$api/actions/runs/$($run.id)/jobs?per_page=100" -Headers $h).jobs } catch { $jobs = @() }
    $jobs = @($jobs | Where-Object { $_.name -like '*E2E*' })
    if ($project) { $jobs = @($jobs | Where-Object { $_.name -like "*($project)*" }) }
    foreach ($job in $jobs) {
      $tmp = Join-Path $env:TEMP ('ci-' + $job.id + '.log')
      if (-not (Get-CiJobLog $job.id $tmp $api $h)) { continue }
      $m = Get-CiMarks ([System.IO.File]::ReadAllLines($tmp)) $spec $grep
      foreach ($k in $m.marks.Keys) { $marks[$k] = [string]$marks[$k] + $m.marks[$k] }
      $sawFail = @($m.marks.Values | Where-Object { ([string]$_).Contains('F') }).Count -gt 0
      if ($isNewest) { $newestTarget += $m.target }
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
        } else {
          $runExcerpts[$sha] = $excerpt.Substring(0, [Math]::Min(800, $excerpt.Length))
        }
      }
      Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    $verdict = Get-CiVerdict @($marks.Values | ForEach-Object { [string]$_ })
    $row = [ordered]@{ date = $date; sha = $sha; verdict = $verdict; url = $run.html_url }
    if ($runSignals.ContainsKey($sha)) { $row.envSignals = $runSignals[$sha] }
    if ($runExcerpts.ContainsKey($sha)) { $row.excerpt = $runExcerpts[$sha] }
    $r.runs += $row
  }

  $r.target = $grep
  if ($grep) { $r.targetVerdict = Get-CiVerdict @(@($newestTarget) | Where-Object { $_ }) }

  $obs = @($r.runs | Where-Object { $_.verdict -in 'failed', 'flaky', 'passed' })
  if ($obs.Count -eq 0) {
    $r.classification = 'absent'
    $r.summary = "$spec did not run in the last $($r.runs.Count) scheduled runs of playwright-ci.yml on $Branch"
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

  $hist = ($r.runs | ForEach-Object { "$($_.date) $($_.sha) $($_.verdict)" }) -join '; '
  $r.summary = "$($r.classification): $spec over the last $($r.runs.Count) nightly runs (newest first): $hist"
  if ($r.firstFailSha) { $r.summary += "; failing since $($r.firstFailSha)" }
  if ($r.lastPassSha) { $r.summary += "; last pass $($r.lastPassSha)" }
  if ($grep) { $r.summary += "; targeted test in the newest run: $($r.targetVerdict)" }
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
  $fail = [string][char]0x2718; $pass = [string][char]0x2713
  $rx = '^(?:\S+Z )?\s*([' + $fail + $pass + '-])\s+\d+\s+\[[^\]]+\]\s+\S+\s+(\S*' + [regex]::Escape($Spec) + ':\d+:\d+)(.*)$'
  $marks = @{}; $target = ''
  foreach ($line in $Lines) {
    $mm = [regex]::Match($line, $rx)
    if (-not $mm.Success) { continue }
    $mark = switch ($mm.Groups[1].Value) { $fail { 'F' } $pass { 'P' } default { 'S' } }
    $k = $mm.Groups[2].Value
    $marks[$k] = [string]$marks[$k] + $mark
    if ($Grep -and $mm.Groups[3].Value -match [regex]::Escape($Grep)) { $target += $mark }
  }
  return @{ marks = $marks; target = $target }
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
  $url = "$Api/actions/jobs/$JobId/logs"
  try { Invoke-WebRequest $url -Headers $Headers -UseBasicParsing -OutFile $Path; return $true } catch { }
  try { Invoke-WebRequest $url -Headers $Headers -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop | Out-Null } catch {
    $loc = $_.Exception.Response.Headers['Location']
    if ($loc) { try { Invoke-WebRequest $loc -UseBasicParsing -OutFile $Path; return $true } catch { } }
  }
  Write-Output "[ci-history] could not fetch log for job $JobId"
  return $false
}

# CI history alone settles a deterministic or flaky verdict; anything else needs a local repro.
function Test-NeedsRepro($CiResult) {
  return -not (@('regression', 'consistent', 'flaky') -contains $CiResult.classification)
}
