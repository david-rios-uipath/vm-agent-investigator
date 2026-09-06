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

# 'Continue', not 'Stop': git, pnpm, npm and Playwright all write progress to stderr, and with
# 'Stop' the first such line becomes a terminating error that kills the phase. Playwright's very
# first progress line did exactly that, after the patch was written but before the verdict.
# Failures are caught explicitly instead - every native call checks $LASTEXITCODE and throws,
# and `throw` stays terminating whatever this is set to.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\prologue.ps1')
. (Join-Path $here 'lib\ci-history.ps1')
. (Join-Path $here 'lib\pr-body.ps1')

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
  $files = @(Get-ChildItem $notes -Recurse -File)
  if ($files.Count -eq 0) { return }
  # One unreadable file makes Compress-Archive fail for the whole set, and a background process
  # can still hold a log open when the phase ends. Stage a copy, skip what cannot be read, and
  # say so - silently pushing nothing is how several runs' state was lost.
  $stage = Join-Path $env:TEMP ('state-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  $skipped = @()
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($notes.Length).TrimStart('\')
    $dest = Join-Path $stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    try { Copy-Item $f.FullName $dest -ErrorAction Stop } catch { $skipped += $rel }
  }
  try {
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $stateZip -Force -ErrorAction Stop
    Write-Output ('[state] archived {0} files, {1:N1} MB{2}' -f ($files.Count - $skipped.Count),
      ((Get-Item $stateZip).Length / 1MB), $(if ($skipped.Count) { ' (unreadable: ' + ($skipped -join ', ') + ')' } else { '' }))
  } catch {
    Write-Output "[state] ARCHIVE FAILED, this run's state is not being pushed: $($_.Exception.Message)"
  } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
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

# Finds the last balanced {...} in the text and parses it. A flat regex is not enough: the
# fixSummary quotes code like `getByRole('button', { name: 'x' })`, so the object's own braces
# are not the outermost ones a naive match finds. Tracks string state so braces inside a JSON
# string value do not affect the depth count.
# Anything unparsable is a soft failure: every field that matters is also derived from the
# filesystem by the caller.
function Get-LastJson([string]$Text) {
  if (-not $Text) { return $null }
  $spans = @()
  $depth = 0; $start = -1; $inStr = $false; $esc = $false
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($inStr) {
      if ($esc) { $esc = $false }
      elseif ($c -eq '\') { $esc = $true }
      elseif ($c -eq '"') { $inStr = $false }
      continue
    }
    if ($c -eq '"') { $inStr = $true }
    elseif ($c -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
    elseif ($c -eq '}') {
      $depth--
      if ($depth -eq 0 -and $start -ge 0) { $spans += , $Text.Substring($start, $i - $start + 1); $start = -1 }
      if ($depth -lt 0) { $depth = 0 }
    }
  }
  for ($i = $spans.Count - 1; $i -ge 0; $i--) {
    try { return ConvertFrom-Json $spans[$i] } catch { }
  }
  return $null
}

# A commit subject, not a paragraph: the model is asked for a short imperative `title`, and
# this is the guard for when it ignores that or returns nothing. A summary that opens with a
# file path burns the whole budget before saying anything, so paths are dropped first.
function New-CommitSubject([string]$Title, [string]$Summary, [string]$Spec, [string]$Scope) {
  $t = $Title.Trim()
  if (-not $t) {
    $t = (($Summary -split "`n")[0]).Trim()
    # "Updated e2e/specs/debug/debug-execution.spec.ts lines 84 and 87 from ..." -> "from ..."
    $t = $t -replace '^\w+\s+\S*/\S+\s*', '' -replace '^(lines?|line)\s+[\d,\s and]+', ''
  }
  $t = $t -replace '^(fix|feat|chore|test)(\([^)]*\))?:\s*', ''   # do not double the prefix
  if (-not $t) { return "$Scope`: repair $Spec" }
  $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1)
  $budget = 72 - $Scope.Length - 2
  if ($t.Length -gt $budget) { $t = ($t.Substring(0, $budget) -replace '\s+\S*$', '') }
  $t = $t -replace '\s*\([^)]*$', '' -replace '[\s(,;:.\-]+$', ''
  if (-not $t) { return "$Scope`: repair $Spec" }
  return "$Scope`: $t"
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
    # E2E_RECORD: playwright.config.ts only records with it set, and the failing run is the
    # "before" clip the PR shows next to the verified fix.
    $out = @(Invoke-Cmd $TestCommand $RepoDir @{ CI = 'true'; E2E_RECORD = '1' } 2>&1)
    $exit = $LASTEXITCODE
    $stdout = ($out -join "`n")
    Write-Utf8Lf (Join-Path $notes 'test-output.log') $stdout
    Write-Output "[repro] exit $exit"
    Write-Output (Get-Tail $stdout 4000)

    # The next job refreshes the checkout, which deletes e2e\test-results. Keep the artifacts
    # in state so the investigate phase can still read the DOM and the trace.
    $results = Join-Path $RepoDir 'e2e\test-results'
    if (Test-Path $results) {
      Save-DemoVideo $results $notes 'bug-demo' | Out-Null
      # The clip is in state as bug-demo.mp4 now; the raw webms are the biggest thing in
      # test-results and would push the copy below over its size guard.
      Get-ChildItem $results -Recurse -Filter *.webm -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
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
  } elseif ($ci.targetVerdict -in 'passed', 'flaky') {
    # The spec failed in CI, but the one test this run is about ended green there: the failure
    # belongs to another test in the file. A flake by definition; nothing to reproduce.
    $source = 'ci'; $exit = 0
    $stdout = "CI: the targeted test ($($ci.target)) ended $($ci.targetVerdict) in the newest nightly; the spec-level failure came from another test. Not re-run."
    Write-Output "[repro] CI shows the targeted test $($ci.targetVerdict) in the newest nightly; flaky, not re-run"
  } else {
    $source = 'ci'; $exit = 1
    $stdout = $ci.ciFailureExcerpt
    if (-not $stdout) { $stdout = '(no CI failure excerpt captured; see ci-job.log)' }
    Write-Output "[repro] CI history already settled this as $($ci.classification); the test was not re-run"
  }

  # Exit 124 is the runner's timeout, not a test verdict.
  $reproduced = if ($source -eq 'ci') { $exit -ne 0 } else { $exit -ne 0 -and $exit -ne 124 }
  $classification = if ($source -eq 'ci' -and $exit -eq 0) { 'flaky' } else { $ci.classification }

  $evidence = [ordered]@{
    source = $source
    exitCode = $exit
    reproduced = $reproduced
    excerpt = Get-Tail $stdout 8000
    ciHistory = $ciHistory
    ciClassification = $classification
    ciRuns = $ci.runs
    firstFailSha = $ci.firstFailSha
    lastPassSha = $ci.lastPassSha
  }
  Write-Utf8Lf (Join-Path $notes 'evidence.json') ($evidence | ConvertTo-Json -Depth 6)

  Write-Status @{
    reproduced = $reproduced
    source = $source
    exitCode = $exit
    classification = $classification
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

  Write-Utf8Lf (Join-Path $notes 'investigation.json') (([ordered]@{
    complete = $complete; hypothesis = $hypothesis
  }) | ConvertTo-Json -Depth 3)

  Write-Status @{
    investigationComplete = $complete
    hypothesis = $hypothesis
    notebook = Get-Tail $body 20000
  }
}

'fix' {
  if (-not (Test-Path $notebook)) {
    Write-Output '[fix] no notebook.md in state; refusing to guess a fix'
    Write-Status @{ patchWritten = $false; fixVerified = $false; declined = $true; fixSummary = 'no investigator notebook in state'; confidence = 'low'; attempt = $FixAttempt }
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
  $fixTitle = if ($json -and $json.title) { [string]$json.title } else { '' }
  $problem = if ($json -and $json.problem) { [string]$json.problem } else { '' }
  $solution = if ($json -and $json.solution) { [string]$json.solution } else { '' }

  # git diff is the arbiter of whether anything was actually changed.
  $diff = (& git -C $RepoDir diff | Out-String)
  $patchWritten = $diff.Trim().Length -gt 0
  if (-not $patchWritten) {
    Write-Output '[fix] working tree is clean; no patch'
    & git -C $RepoDir checkout -- . 2>&1 | Out-Null
    # declined: a retry starts from the same notebook and code and reaches the same verdict.
    Write-Status @{ patchWritten = $false; fixVerified = $false; declined = $true; fixSummary = $fixSummary; confidence = $confidence; attempt = $FixAttempt; patch = '' }
    exit 0
  }
  # Non-ASCII in the fixer's own edits reaches disk mangled (run 130020 committed replacement
  # bytes for an em dash into product source), so say so where the run log and notebook show it.
  $badLines = @(($diff -split "`n") | Where-Object { $_.StartsWith('+') -and $_ -match '[^\u0000-\u007f]' })
  if ($badLines.Count -gt 0) {
    Write-Output "[fix] WARNING: $($badLines.Count) added line(s) contain non-ASCII characters:"
    $badLines | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
  }

  Write-Utf8Lf $patchFile $diff
  Write-Output '[fix] patch'
  Write-Output (Get-Tail $diff 4000)

  # Arbiter run: the phase, not the model, decides whether the fix works.
  $verify = New-Object System.Text.StringBuilder
  function Note([string]$Line) { Write-Output $Line; [void]$verify.AppendLine($Line) }

  # Outside $notes: the dev server holds this open past the end of the phase, and a locked
  # file in the state directory used to sink the whole archive.
  $devlog = Join-Path 'C:\vm-agent' "studio-dev-$RunId.log"
  Note '[verify] starting local studio MFE (pnpm run dev:studio)'
  $dev = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "set `"PATH=$ToolPath;%PATH%`" && corepack pnpm run dev:studio > `"$devlog`" 2>&1" -WorkingDirectory $RepoDir -PassThru -WindowStyle Hidden
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
    # Only worth keeping in state when it explains a failure.
    Copy-Item $devlog (Join-Path $notes 'studio-dev.log') -ErrorAction SilentlyContinue
  } else {
    Note "[verify] studio MFE serving on port $port"
    $cmd = "$localCmd --retries=0 --reporter=line"
    # Cold auth ("Storage state is invalid ... regenerating") runs inside the spec's own 120 s
    # beforeEach budget and, with a cold dev server on a 2-CPU VM, times out in setup before the
    # test reaches the step the patch is about. When there is no storage state yet, run the test
    # once to log in and warm the server; only the second run counts.
    $env = @{ CI = 'true'; E2E_SKIP_WEBSERVER = '1'; E2E_STUDIO_PORT = $port }
    if (-not (Get-ChildItem (Join-Path $RepoDir 'e2e') -Filter '*.storage-state.json' -ErrorAction SilentlyContinue)) {
      Note '[verify] no storage state on this VM: warm-up run first (logs in, warms the dev server; result not counted)'
      $warm = @(Invoke-Cmd $cmd $RepoDir $env 2>&1)
      Note "[verify] warm-up exit $LASTEXITCODE"
    }
    Note "[verify] $cmd"
    # E2E_SKIP_WEBSERVER: the workbench Vite server is only for the standalone project and would
    # otherwise cost ~120 s and contend for port 3000 with the studio dev server.
    $env['E2E_RECORD'] = '1'
    $out = @(Invoke-Cmd $cmd $RepoDir $env 2>&1)
    $exit = $LASTEXITCODE
    $out | Select-Object -Last 60 | ForEach-Object { Note "  $_" }
    Note "[verify] test exit $exit"
    $fixVerified = ($exit -eq 0)
    Save-DemoVideo (Join-Path $RepoDir 'e2e\test-results') $notes 'fix-demo' ${function:Note} | Out-Null
  }

  taskkill /PID $dev.Id /T /F 2>&1 | Out-Null
  & git -C $RepoDir checkout -- . 2>&1 | Out-Null
  & git -C $RepoDir clean -fd -- e2e 2>&1 | Out-Null

  Write-Utf8Lf $prevFile $verify.ToString()
  Write-Utf8Lf (Join-Path $notes 'fix-summary.json') (([ordered]@{
    title = $fixTitle; problem = $problem; solution = $solution
    fixSummary = $fixSummary; confidence = $confidence
    attempts = $FixAttempt; verified = $fixVerified
  }) | ConvertTo-Json -Depth 4)

  Write-Status @{
    patchWritten = $true
    fixVerified = $fixVerified
    fixSummary = $fixSummary
    title = $fixTitle
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
  $summary = if (Test-Path $summaryFile) { Get-Content -Raw $summaryFile | ConvertFrom-Json } else { $null }
  $fixSummary = if ($summary) { [string]$summary.fixSummary } else { '' }
  $ownerRepo = (($RepoUrl -replace '^https://github.com/', '') -replace '\.git$', '').Trim('/')
  # Prefer the .spec.ts: the plain .ts branch matches `playwright.config.ts` first, which is how
  # run 130020's PR came out titled `- Spec: playwright.config` (same trap as deriveRunId).
  $spec = if ($TestCommand -match '([\w.-]+?)\.spec\.ts\b') { $Matches[1] } elseif ($TestCommand -match '([\w.-]+?)\.ts\b') { $Matches[1] } else { 'e2e' }
  $prBranch = "e2e-investigator/$RunId"

  # e2e-only changes get the scope the repo uses for them.
  $numstat = @(& git -C $RepoDir apply --numstat $patchFile 2>$null)
  $touched = @($numstat | ForEach-Object { ($_ -split "`t")[2] })
  $scope = if ($touched.Count -gt 0 -and -not ($touched | Where-Object { $_ -notlike 'e2e/*' })) { 'fix(e2e)' } else { 'fix' }
  $title = New-CommitSubject $(if ($summary) { [string]$summary.title } else { '' }) $fixSummary $spec $scope
  Write-Output "[pr] $title" 

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
  $commitMsg = "$title`n`nVerified by re-running the spec. Automated investigator run $RunId."
  $commitOut = @(& git -C $RepoDir -c user.name='e2e-investigator' -c user.email='e2e-investigator@uipath.com' commit -am $commitMsg 2>&1)
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

  $env:GH_PROMPT_DISABLED = '1'
  # GitHub caps attachments (10 MB for images, more for video), and a two-minute e2e run makes a
  # large gif. Prefer the mp4 player, fall back to the gif, skip rather than fail the PR.
  # gh appends attachments to the body in the order given, and a video carries no alt text, so
  # the body names that order instead - see $captions below.
  $attachArgs = @(); $captions = @()
  foreach ($clip in @(
      @{ base = 'bug-demo'; caption = 'the spec failing before the fix' },
      @{ base = 'fix-demo'; caption = 'the spec passing with the fix applied' })) {
    $mp4 = Join-Path $notes ($clip.base + '.mp4'); $gif = Join-Path $notes ($clip.base + '.gif')
    if ((Test-Path $mp4) -and (Get-Item $mp4).Length -lt 24MB) {
      $attachArgs += @('--attach', $mp4)
      $captions += $clip.caption
      Write-Output ('[pr] attaching {0}.mp4 ({1:N1} MB)' -f $clip.base, ((Get-Item $mp4).Length / 1MB))
    } elseif ((Test-Path $gif) -and (Get-Item $gif).Length -lt 9MB) {
      $attachArgs += @('--attach', ('{0}#The e2e spec: {1}' -f $gif, $clip.caption))
      $captions += $clip.caption
      Write-Output ('[pr] attaching {0}.gif ({1:N1} MB)' -f $clip.base, ((Get-Item $gif).Length / 1MB))
    }
  }
  if ($attachArgs.Count -eq 0) {
    Write-Output '[pr] no attachable recording under the size limit; see the run state in the bucket'
  }

  $bodyFile = Join-Path $notes 'pr-body.md'
  Write-Utf8Lf $bodyFile (New-PrBody $notes $RunId $spec $numstat $captions)
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
