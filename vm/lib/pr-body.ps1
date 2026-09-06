<#
Builds the pull request description for the pr phase.

A reviewer reads the top two sentences and nothing else, so the shape is fixed: one-sentence
Problem, one-sentence Solution, and every supporting detail behind a <details> block - failure
output, what changed and how it was verified, then the investigator notebook.

Built line by line rather than from a here-string: the notebook and the logs contain `$` and
backticks that a double-quoted here-string would interpolate.
#>
# The fixer is asked for bullets and sometimes returns one 250-word paragraph anyway (run
# 130020, and again in flow-workbench#3729). Prompt wording alone has not held, so any prose
# that arrives without bullets is packed into them here: sentences grouped to roughly $Width
# characters, split only on ". " before a capital so `NeighborRail.test.tsx` stays whole.
function Format-Prose([string]$Text, [int]$Width = 220) {
  if (-not $Text) { return '' }
  $t = $Text.Trim()
  # Already structured (bullets, numbered list or blank-line paragraphs): leave it alone.
  if ($t -match '(?m)^\s*([-*]|\d+\.)\s' -or $t -match "\n\s*\n") { return $t }
  if ($t.Length -le $Width) { return $t }

  $sentences = [regex]::Split($t, '(?<=[.!?])\s+(?=[A-Z(`"])') | Where-Object { $_.Trim() }
  if ($sentences.Count -lt 2) { return $t }

  $bullets = New-Object System.Collections.Generic.List[string]
  $cur = ''
  foreach ($sentence in $sentences) {
    $s = $sentence.Trim()
    if (-not $cur) { $cur = $s }
    elseif (($cur.Length + 1 + $s.Length) -le $Width) { $cur += ' ' + $s }
    else { $bullets.Add($cur); $cur = $s }
  }
  if ($cur) { $bullets.Add($cur) }
  return (($bullets | ForEach-Object { "- $_" }) -join "`n")
}

function New-PrBody {
  param(
    [Parameter(Mandatory)][string] $Notes,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $Spec,
    [string[]] $NumStat = @(),
    # Captions for the clips the pr phase attaches, in attach order. gh appends them below the
    # body and a video takes no alt text, so this is the only place a reader learns which is which.
    [string[]] $Captions = @()
  )
  $Summary = if (Test-Path (Join-Path $Notes 'fix-summary.json')) { Get-Content -Raw (Join-Path $Notes 'fix-summary.json') | ConvertFrom-Json } else { $null }
  $fixSummary = if ($Summary -and $Summary.fixSummary) { [string]$Summary.fixSummary } else { '' }
  $ev = if (Test-Path (Join-Path $Notes 'evidence.json')) { Get-Content -Raw (Join-Path $Notes 'evidence.json') | ConvertFrom-Json } else { $null }
  $inv = if (Test-Path (Join-Path $Notes 'investigation.json')) { Get-Content -Raw (Join-Path $Notes 'investigation.json') | ConvertFrom-Json } else { $null }
  $notebookBody = if (Test-Path (Join-Path $Notes 'notebook.md')) { Get-Content -Raw (Join-Path $Notes 'notebook.md') } else { '' }
  $verifyBody = if (Test-Path (Join-Path $Notes 'verify-output.log')) { Get-Content -Raw (Join-Path $Notes 'verify-output.log') } else { '' }

  $problem = if ($Summary -and $Summary.problem) { [string]$Summary.problem } elseif ($inv -and $inv.hypothesis) { [string]$inv.hypothesis } else { '_The fixer did not state a one-line cause; see the investigation below._' }
  $solution = if ($Summary -and $Summary.solution) { [string]$Summary.solution } elseif ($fixSummary) { (($fixSummary -split '(?<=\.)\s+') | Select-Object -First 1) } else { '_No summary returned; read the diff._' }

  $lines = New-Object System.Collections.Generic.List[string]
  function Add-Line([string]$Text = '') { $lines.Add($Text) }
  # Logs come back through the VM's legacy codepage, so Playwright's box-drawing rules land as
  # mojibake and its cursor moves as raw ANSI escapes. Neither means anything to a reviewer.
  function Add-Fence([string]$Text, [int]$Max) {
    if (-not $Text -or -not $Text.Trim()) { Add-Line '_(nothing captured)_'; return }
    $clean = (Get-Tail $Text $Max) -replace "\u001b\[[0-9;?]*[a-zA-Z]", '' -replace '[^\u0020-\u007e\t\r\n]', ''
    $clean = ($clean -split "`n" | Where-Object { $_.Trim() }) -join "`n"
    Add-Line '```text'
    Add-Line $clean.TrimEnd()
    Add-Line '```'
  }

  Add-Line '## Problem'
  Add-Line ''
  Add-Line $problem
  Add-Line ''
  Add-Line '<details>'
  Add-Line '<summary>How it failed</summary>'
  Add-Line ''
  Add-Line ('- Spec: `{0}`' -f $Spec)
  if ($ev) {
  $src = if ($ev.source -eq 'ci') { 'CI history only (the spec was not re-run here)' } else { 're-run on the investigator VM' }
  Add-Line ('- Evidence: {0}, exit code {1}' -f $src, $ev.exitCode)
  if ($ev.classification) { Add-Line ('- CI classification: {0}' -f $ev.classification) }
  # No local recording exists on this path (the spec was never run here), so the nightly run
  # itself is the evidence a reviewer can open.
  if ($ev.source -eq 'ci') {
    $night = @($ev.ciRuns | Where-Object { $_.url -and $_.verdict -in 'failed', 'flaky' })[0]
    if ($night) { Add-Line ('- Nightly run: {0} (`{1}`, {2})' -f $night.url, $night.sha, $night.date) }
  }
  if ($ev.firstFailSha) {
    $since = '- Failing since `{0}`' -f $ev.firstFailSha
    if ($ev.lastPassSha) { $since += ', last green `{0}`' -f $ev.lastPassSha }
    Add-Line $since
  }
  }
  Add-Line ''
  Add-Line 'Failure output:'
  Add-Line ''
  Add-Fence $(if ($ev) { [string]$ev.excerpt } else { '' }) 2500
  Add-Line ''
  Add-Line '</details>'
  Add-Line ''
  Add-Line '## Solution'
  Add-Line ''
  Add-Line $solution
  Add-Line ''
  Add-Line '<details>'
  Add-Line '<summary>What changed, and how it was verified</summary>'
  Add-Line ''
  if ($fixSummary) { Add-Line (Format-Prose $fixSummary); Add-Line '' }
  if ($NumStat.Count -gt 0) {
    Add-Line 'Files changed:'
    Add-Line ''
    foreach ($row in $NumStat) {
      $cols = $row -split "`t"
      if ($cols.Count -ge 3) { Add-Line ('- `{0}` (+{1}/-{2})' -f $cols[2], $cols[0], $cols[1]) }
    }
    Add-Line ''
  }
  $conf = if ($Summary -and $Summary.confidence) { [string]$Summary.confidence } else { 'unstated' }
  $tries = if ($Summary -and $Summary.attempts) { [string]$Summary.attempts } else { '1' }
  # Never claim a pass the phase did not see: openPr only runs after a verified fix today, but a
  # flow change that let an unverified patch through would otherwise publish a false claim.
  $verdict = if ($Summary -and -not $Summary.verified) { 'The spec was re-run with `--retries=0` against a locally served studio bundle and did NOT pass' } else { 'Verified by re-running the spec with `--retries=0` against a locally served studio bundle; it passed' }
  Add-Line ('{0}. Fixer confidence: **{1}**, on attempt {2}.' -f $verdict, $conf, $tries)
  Add-Line ''
  Add-Line 'Verification output:'
  Add-Line ''
  Add-Fence $verifyBody 3000
  Add-Line ''
  Add-Line '</details>'
  Add-Line ''
  Add-Line '<details>'
  Add-Line '<summary>Investigation notebook (what was probed, and what was ruled out)</summary>'
  Add-Line ''
  if ($notebookBody.Trim()) { Add-Line (Get-Tail $notebookBody 30000).TrimEnd() } else { Add-Line '_No notebook in state._' }
  Add-Line ''
  Add-Line '</details>'
  Add-Line ''
  Add-Line '---'
  Add-Line ''
  if ($Captions.Count -gt 0) {
    Add-Line ('Recording{0} below, in order: {1}.' -f $(if ($Captions.Count -gt 1) { 's' } else { '' }),
      (($Captions | ForEach-Object { '**' + $_ + '**' }) -join ', then '))
    Add-Line ''
  }
  Add-Line ('Automated e2e investigator, run `{0}`. Full logs and state: bucket `e2e-investigations/{0}/`.' -f $RunId)

  $lines -join "`n"
}
