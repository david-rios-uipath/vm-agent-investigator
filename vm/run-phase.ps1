<#
One phase of the e2e investigator, run as one complete Orchestrator job.

Consecutive jobs may land on different VMs in the pool, so a phase assumes nothing left on
disk: it refreshes the checkout, reads its state from C:\vm-agent\notes\<RunId> (which vm_exec
pulls from the bucket before the script and pushes back afterwards), and prints one
STATUS_JSON= line as its last line of stdout. That line is all the flow parses.

Exit 0 with a negative status (not reproduced, fix not verified) is a normal result.
A non-zero exit means the runner itself broke.
#>
param(
  [Parameter(Mandatory)][ValidateSet('repro', 'investigate', 'fix', 'pr')][string] $Phase,
  [Parameter(Mandatory)][string] $RunId,
  [Parameter(Mandatory)][string] $RepoUrl,
  [Parameter(Mandatory)][string] $Branch,
  [Parameter(Mandatory)][string] $TestCommand,
  [string] $Model = '',
  [int] $FixAttempt = 1,
  [int] $MaxFixAttempts = 3,
  [switch] $SmokeOnly
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\prologue.ps1')
. (Join-Path $here 'lib\ci-history.ps1')

$notes = Join-Path 'C:\vm-agent\notes' $RunId
New-Item -ItemType Directory -Force -Path $notes | Out-Null
$notebook = Join-Path $notes 'notebook.md'
$patchFile = Join-Path $notes 'fix.patch'

# One archive per run, in the bucket at <runId>/state.zip. vm_exec downloads it to this exact
# path before the script and uploads it back afterwards; expanding and rewriting it is ours.
$stateZip = 'C:\vm-agent\' + ($RunId -replace '[\\/]', '_') + '.state.zip'
if (Test-Path $stateZip) {
  Expand-Archive -Path $stateZip -DestinationPath $notes -Force
  Write-Output ("[state] pulled " + @(Get-ChildItem $notes -File).Count + " files from $stateZip")
} else {
  Write-Output '[state] no state archive for this run yet'
}
function Write-StateArchive {
  if (-not (Test-Path $notes)) { return }
  if (@(Get-ChildItem $notes -Recurse -File).Count -eq 0) { return }
  Compress-Archive -Path (Join-Path $notes '*') -DestinationPath $stateZip -Force -ErrorAction SilentlyContinue
}

Write-Output "[phase] $Phase runId=$RunId branch=$Branch"
try {
  Ensure-Tools
  Refresh-Repo $RepoUrl $Branch
} catch {
  Write-Output "[phase] prologue failed: $_"
  exit 1
}

# ---------------------------------------------------------------- claude helpers

function New-Prompt([string]$Template, [hashtable]$Values) {
  $text = Get-Content -Raw (Join-Path $here "prompts\$Template")
  foreach ($k in $Values.Keys) { $text = $text.Replace("{{$k}}", [string]$Values[$k]) }
  $file = Join-Path $notes "prompt-$Phase.md"
  Write-Utf8Lf $file $text
  return $file
}

function Invoke-Claude([string]$PromptFile, [string]$AllowedTools, [int]$MaxTurns, [string]$PermissionMode) {
  $transcript = Join-Path $notes "claude-$Phase.jsonl"
  $claudeArgs = @('-p', '--output-format', 'stream-json', '--verbose', '--max-turns', "$MaxTurns", '--allowed-tools', $AllowedTools)
  if ($PermissionMode) { $claudeArgs += @('--permission-mode', $PermissionMode) }
  # Empty means whatever the account default is; set it to run cheap models while testing.
  if ($Model) { $claudeArgs += @('--model', $Model) }
  Write-Host "[claude] claude $($claudeArgs -join ' ')"
  Push-Location $RepoDir
  try {
    # Transcript to file, not to stdout: the exec log's tail must end at STATUS_JSON=.
    Get-Content -Raw $PromptFile | & claude @claudeArgs 2>&1 | Out-File -FilePath $transcript -Encoding utf8
  } finally { Pop-Location }
  $lines = @(Get-Content $transcript -ErrorAction SilentlyContinue)
  Write-Host "[claude] $($lines.Count) transcript lines -> $transcript"
  $resultLine = $lines | Where-Object { $_ -match '"type"\s*:\s*"result"' } | Select-Object -Last 1
  if (-not $resultLine) {
    Write-Host '[claude] no result event in the transcript; last 3 lines:'
    $lines | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
    return ''
  }
  $r = $null
  try { $r = ConvertFrom-Json $resultLine } catch { }
  if ($r) {
    # error_max_turns means the run was cut off mid-thought: whatever it had not yet written
    # to the notebook is lost, and that is a budget problem, not a model failure.
    # Single-quoted format string: in a double-quoted one PowerShell reads {4:N2} preceded by
    # a dollar as ${...} variable syntax and eats the placeholder, printing a bare "cost $".
    Write-Host ('[claude] ended {0}{1} after {2} turns in {3}s, cost ${4:N4}' -f `
      $r.subtype, $(if ($r.is_error) { ' (ERROR)' } else { '' }), $r.num_turns,
      [int]($r.duration_ms / 1000), [double]$r.total_cost_usd)
  }
  $text = ''
  try { $text = [string]$r.result } catch { }
  Write-Host '[claude] final message:'
  Write-Host (Get-Tail $text 2000)
  return $text
}

# The prompts ask for one flat JSON object as the last message. Anything else is a soft failure:
# every field that matters is also derived from the filesystem by the caller.
function Get-LastJson([string]$Text) {
  if (-not $Text) { return $null }
  $found = [regex]::Matches($Text, '\{[^{}]*\}')
  for ($i = $found.Count - 1; $i -ge 0; $i--) {
    try { return ConvertFrom-Json $found[$i].Value } catch { }
  }
  return $null
}

# ---------------------------------------------------------------- phases

# The archive is rewritten however the phase ends, including the early exits below; vm_exec
# uploads it after the script returns.
try {
switch ($Phase) {

'repro' {
  if ($SmokeOnly) {
    # Same stub the old flow used, so a smoke iteration costs ~2 minutes instead of ~10.
    $ci = @{ classification = 'flaky'; summary = 'smoke stub'; firstFailSha = ''; lastPassSha = ''
             runs = @(); ciFailureExcerpt = 'smoke stub: no CI lookup'; ciJobLog = '' }
  } else {
    $ci = Get-CiHistory $RepoUrl $Branch $TestCommand $notes
  }
  Write-Output "[ci-history] $($ci.classification): $($ci.summary)"

  # One string for the prompts: the verdict plus the failure excerpt from every OTHER failing
  # night, so a shared-environment pattern is visible without extra probing.
  $others = @($ci.runs | Where-Object { $_.excerpt })
  $ciHistory = $ci.summary
  if ($others.Count -gt 0) {
    $ciHistory += "`n`nOther failing nights (excerpts):`n" + (($others | ForEach-Object {
      "--- $($_.date) $($_.sha) ($($_.verdict))" + $(if ($_.envSignals) { ' env=' + ($_.envSignals | ConvertTo-Json -Compress) } else { '' }) + "`n$($_.excerpt)"
    }) -join "`n")
  }

  if ($SmokeOnly) {
    $source = 'vm'; $exit = 1
    $stdout = 'smoke stub: the test was not run'
    Write-Output '[repro] smoke: skipped the test run'
  } elseif (Test-NeedsRepro $ci) {
    $source = 'vm'
    Write-Output "[repro] $TestCommand"
    $out = @(Invoke-Cmd $TestCommand $RepoDir @{ CI = 'true' } 2>&1)
    $exit = $LASTEXITCODE
    $stdout = ($out -join "`n")
    Write-Utf8Lf (Join-Path $notes 'test-output.log') $stdout
    Write-Output "[repro] exit $exit"
    Write-Output (Get-Tail $stdout 4000)

    # The next job refreshes the checkout, which deletes e2e\test-results. Keep the artifacts
    # in state so the investigate phase can still read the DOM and the trace.
    $results = Join-Path $RepoDir 'e2e\test-results'
    if (Test-Path $results) {
      $dest = Join-Path $notes 'test-results'
      $size = (Get-ChildItem $results -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      if ($size -lt 25MB) {
        Copy-Item "$results\*" $dest -Recurse -Force
        Write-Output "[repro] copied $([int]($size/1MB)) MB of Playwright artifacts to state"
      } else {
        Get-ChildItem $results -Recurse -File -Filter *.md | ForEach-Object { Copy-Item $_.FullName $dest -Force }
        Write-Output "[repro] artifacts are $([int]($size/1MB)) MB; kept only the .md context files"
      }
    }
  } else {
    $source = 'ci'; $exit = 1
    $stdout = $ci.ciFailureExcerpt
    if (-not $stdout) { $stdout = '(no CI failure excerpt captured; see ci-job.log)' }
    Write-Output "[repro] CI history already settled this as $($ci.classification); the test was not re-run"
  }

  # Exit 124 is the runner's timeout, not a test verdict.
  $reproduced = if ($source -eq 'ci') { $true } else { $exit -ne 0 -and $exit -ne 124 }

  $evidence = [ordered]@{
    source = $source
    exitCode = $exit
    reproduced = $reproduced
    excerpt = Get-Tail $stdout 8000
    ciHistory = $ciHistory
    ciClassification = $ci.classification
    ciRuns = $ci.runs
    firstFailSha = $ci.firstFailSha
    lastPassSha = $ci.lastPassSha
  }
  Write-Utf8Lf (Join-Path $notes 'evidence.json') ($evidence | ConvertTo-Json -Depth 6)

  Write-Status @{
    reproduced = $reproduced
    source = $source
    exitCode = $exit
    classification = $ci.classification
    excerpt = Get-Tail $stdout 3000
    ciHistory = Get-Tail $ciHistory 4000
  }
}

'investigate' {
  $evidenceFile = Join-Path $notes 'evidence.json'
  if (-not (Test-Path $evidenceFile)) {
    Write-Output '[investigate] no evidence.json in state; nothing to investigate'
    Write-Status @{ investigationComplete = $false; hypothesis = ''; notebook = ''; error = 'evidence.json missing from state' }
    exit 0
  }
  $ev = Get-Content -Raw $evidenceFile | ConvertFrom-Json

  $prompt = New-Prompt 'investigator.md' @{
    REPO_URL = $RepoUrl; BRANCH = $Branch; TEST_COMMAND = $TestCommand; RUN_ID = $RunId
    SOURCE = $ev.source; EXIT_CODE = $ev.exitCode; CI_HISTORY = $ev.ciHistory
    OUTPUT_TAIL = $ev.excerpt; NOTES_DIR = $notes
  }
  $final = Invoke-Claude $prompt 'Read,Grep,Glob,Bash(rg:*),Bash(git log:*),Bash(git show:*),Bash(git diff:*),Bash(git blame:*),Bash(git merge-base:*),Bash(git fetch:*),Write' 80 $null
  $json = Get-LastJson $final

  # The notebook on disk is the truth, not the model's self-report.
  $body = if (Test-Path $notebook) { Get-Content -Raw $notebook } else { '' }
  $complete = $body.Trim().Length -gt 200
  $hypothesis = if ($json -and $json.hypothesis) { [string]$json.hypothesis } else { '' }
  if (-not $complete) { Write-Output "[investigate] notebook is missing or too short ($($body.Length) chars)" }

  Write-Status @{
    investigationComplete = $complete
    hypothesis = $hypothesis
    notebook = Get-Tail $body 20000
  }
}

'fix' {
  if (-not (Test-Path $notebook)) {
    Write-Output '[fix] no notebook.md in state; refusing to guess a fix'
    Write-Status @{ patchWritten = $false; fixVerified = $false; fixSummary = 'no investigator notebook in state'; confidence = 'low'; attempt = $FixAttempt }
    exit 0
  }
  $ev = if (Test-Path (Join-Path $notes 'evidence.json')) { Get-Content -Raw (Join-Path $notes 'evidence.json') | ConvertFrom-Json } else { $null }
  $prevVerify = ''
  $prevFile = Join-Path $notes 'verify-output.log'
  if ($FixAttempt -gt 1 -and (Test-Path $prevFile)) { $prevVerify = Get-Tail (Get-Content -Raw $prevFile) 6000 }

  # studio-alpha loads the flow MFE from alpha's deployed bundle, so a product-source patch
  # would apply, run and change nothing. studio-local keeps the alpha backend and serves the
  # patched bundle locally.
  $localCmd = $TestCommand.Replace('--project studio-alpha', '--project studio-local')

  $prompt = New-Prompt 'fixer.md' @{
    REPO_URL = $RepoUrl; BRANCH = $Branch; RUN_ID = $RunId; NOTES_DIR = $notes
    ATTEMPT = $FixAttempt; MAX_ATTEMPTS = $MaxFixAttempts
    EXIT_CODE = $(if ($ev) { $ev.exitCode } else { '' })
    OUTPUT_TAIL = $(if ($ev) { Get-Tail $ev.excerpt 4000 } else { '' })
    LOCAL_TEST_COMMAND = $localCmd
    VERIFY_OUTPUT = $prevVerify
    NOTEBOOK = Get-Content -Raw $notebook
  }
  $final = Invoke-Claude $prompt 'Read,Edit,Write,Grep,Glob,Bash' 120 'acceptEdits'
  $json = Get-LastJson $final
  $fixSummary = if ($json -and $json.fixSummary) { [string]$json.fixSummary } else { '(no fixSummary returned)' }
  $confidence = if ($json -and $json.confidence) { [string]$json.confidence } else { 'low' }

  # git diff is the arbiter of whether anything was actually changed.
  $diff = (& git -C $RepoDir diff | Out-String)
  $patchWritten = $diff.Trim().Length -gt 0
  if (-not $patchWritten) {
    Write-Output '[fix] working tree is clean; no patch'
    & git -C $RepoDir checkout -- . 2>&1 | Out-Null
    Write-Status @{ patchWritten = $false; fixVerified = $false; fixSummary = $fixSummary; confidence = $confidence; attempt = $FixAttempt; patch = '' }
    exit 0
  }
  Write-Utf8Lf $patchFile $diff
  Write-Output '[fix] patch'
  Write-Output (Get-Tail $diff 4000)

  # Arbiter run: the phase, not the model, decides whether the fix works.
  $verify = New-Object System.Text.StringBuilder
  function Note([string]$Line) { Write-Output $Line; [void]$verify.AppendLine($Line) }

  $devlog = Join-Path $notes 'studio-dev.log'
  Note '[verify] starting local studio MFE (pnpm run dev:studio)'
  $dev = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "set `"PATH=$Bin;$NodeBin;%PATH%`" && corepack pnpm run dev:studio > `"$devlog`" 2>&1" -WorkingDirectory $RepoDir -PassThru -WindowStyle Hidden
  $port = ''
  foreach ($attempt in 1..60) {
    foreach ($p in 3000, 3001) {
      try {
        $resp = Invoke-WebRequest "http://localhost:$p/remoteEntry.js" -UseBasicParsing -TimeoutSec 3
        # rsbuild serves the SPA index.html fallback for unknown paths while still building;
        # only a non-HTML body means the module federation remote is really up.
        if ($resp.StatusCode -eq 200 -and -not $resp.Content.TrimStart().StartsWith('<')) { $port = "$p"; break }
      } catch { }
    }
    if ($port) { break }
    Start-Sleep -Seconds 5
  }

  $fixVerified = $false
  if (-not $port) {
    Note '[verify] the studio dev server never served remoteEntry.js; tail of its log:'
    Get-Content $devlog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Note "  $_" }
  } else {
    Note "[verify] studio MFE serving on port $port"
    $cmd = "$localCmd --retries=0 --reporter=line"
    Note "[verify] $cmd"
    # E2E_SKIP_WEBSERVER: the workbench Vite server is only for the standalone project and would
    # otherwise cost ~120 s and contend for port 3000 with the studio dev server.
    $out = @(Invoke-Cmd $cmd $RepoDir @{ CI = 'true'; E2E_SKIP_WEBSERVER = '1'; E2E_STUDIO_PORT = $port; E2E_RECORD = '1' } 2>&1)
    $exit = $LASTEXITCODE
    $out | Select-Object -Last 60 | ForEach-Object { Note "  $_" }
    Note "[verify] test exit $exit"
    $fixVerified = ($exit -eq 0)
    $video = Get-ChildItem (Join-Path $RepoDir 'e2e\test-results') -Recurse -Filter *.webm -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($video) { Copy-Item $video.FullName (Join-Path $notes 'video.webm') -Force; Note '[verify] video saved to state' }
  }

  taskkill /PID $dev.Id /T /F 2>&1 | Out-Null
  & git -C $RepoDir checkout -- . 2>&1 | Out-Null
  & git -C $RepoDir clean -fd -- e2e 2>&1 | Out-Null

  Write-Utf8Lf $prevFile $verify.ToString()
  Write-Utf8Lf (Join-Path $notes 'fix-summary.json') (([ordered]@{
    fixSummary = $fixSummary; confidence = $confidence; attempts = $FixAttempt; verified = $fixVerified
  }) | ConvertTo-Json -Depth 4)

  Write-Status @{
    patchWritten = $true
    fixVerified = $fixVerified
    fixSummary = $fixSummary
    confidence = $confidence
    attempt = $FixAttempt
    patch = Get-Tail $diff 6000
  }
}

'pr' {
  if (-not (Test-Path $patchFile)) {
    Write-Output '[pr] no fix.patch in state; skipping'
    Write-Status @{ prUrl = ''; error = 'fix.patch missing from state' }
    exit 0
  }
  if (-not $env:GH_TOKEN) {
    Write-Output '[pr] GH_TOKEN not set; skipping'
    Write-Status @{ prUrl = ''; error = 'GH_TOKEN not set on the VM' }
    exit 0
  }

  $summaryFile = Join-Path $notes 'fix-summary.json'
  $fixSummary = if (Test-Path $summaryFile) { [string](Get-Content -Raw $summaryFile | ConvertFrom-Json).fixSummary } else { '' }
  $ownerRepo = (($RepoUrl -replace '^https://github.com/', '') -replace '\.git$', '').Trim('/')
  $spec = if ($TestCommand -match '([\w.-]+?)(?:\.spec)?\.ts\b') { $Matches[1] } else { 'e2e' }
  $prBranch = "e2e-investigator/$RunId"

  # First line of the fix summary, cut at a word boundary and stripped of a dangling clause.
  $short = ((($fixSummary -split "`n")[0]).Trim())
  if ($short.Length -gt 60) { $short = $short.Substring(0, 60) -replace '\s+\S*$', '' }
  $short = $short -replace '\s*\([^)]*$', '' -replace '[\s(,;:-]+$', ''
  $title = if ($short) { "fix: $short (automated investigator)" } else { "test(e2e): fix $spec (automated investigator)" }

  $tokenRe = [regex]::Escape($env:GH_TOKEN)
  function Reset-Tree {
    & git -C $RepoDir checkout -- . 2>&1 | Out-Null
    & git -C $RepoDir checkout --detach 2>&1 | Out-Null
    & git -C $RepoDir branch -D $prBranch 2>&1 | Out-Null
  }

  & git -C $RepoDir checkout -B $prBranch HEAD 2>&1 | ForEach-Object { Write-Output "$_" }
  & git -C $RepoDir apply $patchFile 2>&1 | ForEach-Object { Write-Output "$_" }
  if ($LASTEXITCODE -ne 0) {
    Write-Output '[pr] git apply failed'
    Reset-Tree
    Write-Status @{ prUrl = ''; error = 'git apply failed' }
    exit 0
  }

  # Capture the exit code before any pipeline that could reset it (FINDINGS-uip.md).
  $commitOut = @(& git -C $RepoDir -c user.name='e2e-investigator' -c user.email='e2e-investigator@uipath.com' commit -am $title 2>&1)
  $commitRc = $LASTEXITCODE
  $commitOut | Select-Object -First 2 | ForEach-Object { Write-Output "$_" }
  if ($commitRc -ne 0) {
    Write-Output "[pr] git commit failed (exit $commitRc)"
    Reset-Tree
    Write-Status @{ prUrl = ''; error = "git commit failed with $commitRc" }
    exit 0
  }
  $commit = (& git -C $RepoDir rev-parse --short HEAD)

  $pushUrl = "https://x-access-token:$($env:GH_TOKEN)@github.com/$ownerRepo.git"
  & git -C $RepoDir push -f $pushUrl $prBranch 2>&1 | ForEach-Object { Write-Output ("$_" -replace $tokenRe, '***') }
  if ($LASTEXITCODE -ne 0) {
    Write-Output '[pr] git push failed'
    Reset-Tree
    Write-Status @{ prUrl = ''; error = 'git push failed' }
    exit 0
  }

  $bodyFile = Join-Path $notes 'pr-body.md'
  Write-Utf8Lf $bodyFile @"
Automated fix from the e2e investigator flow.

Run: $RunId

## Fix summary
$fixSummary

## Verification
Spec re-run with --retries=0 passed after applying this patch (see flow run $RunId).

Notebook and full logs: bucket e2e-investigations/$RunId/
"@

  $env:GH_PROMPT_DISABLED = '1'
  $video = Join-Path $notes 'video.webm'
  $attachArgs = if (Test-Path $video) { @('--attach', $video) } else { @() }
  $out = @(gh pr create --draft --repo $ownerRepo --base $Branch --head $prBranch --title $title --body-file $bodyFile @attachArgs 2>&1 |
    ForEach-Object { "$_" -replace $tokenRe, '***' })
  $out | ForEach-Object { Write-Output $_ }
  $url = $out | Where-Object { $_ -like 'https://*' } | Select-Object -Last 1
  if (-not $url) { Write-Output '[pr] gh pr create did not return a URL' }

  Write-Utf8Lf (Join-Path $notes 'pr.json') (([ordered]@{ prUrl = [string]$url; branch = $prBranch; commit = $commit }) | ConvertTo-Json -Depth 3)
  Reset-Tree
  Write-Status @{ prUrl = [string]$url; branch = $prBranch; commit = $commit }
}

}
} finally { Write-StateArchive }
