<#
Builds the per-group report the `report` phase renders into state and uploads to the nightly's
Slack thread, and the one-line verdict that rides with it as the upload's initial_comment.

Everything comes from files the earlier phases already wrote into $notes: no model call, and
nothing routed back through flow variables (4 x 20 KB of notebook is exactly what blew the
instance-variable cap once already).

Built line by line rather than from a here-string, for the same reason as pr-body.ps1: the
notebook and the diff are full of `$` and backticks a double-quoted here-string would eat.
Source stays pure ASCII - PowerShell 5.1 reads these files in the VM's legacy codepage, so a
literal non-ASCII character here arrives mangled on the VM.
#>
$script:ReportArrow = [string][char]0x203A   # single right-pointing angle quote
$script:ReportDot = [string][char]0x00B7     # middle dot

function Read-StateJson([string]$Notes, [string]$Name) {
  $p = Join-Path $Notes $Name
  if (-not (Test-Path $p)) { return $null }
  try { return Get-Content -Raw $p | ConvertFrom-Json } catch { return $null }
}

function Read-StateText([string]$Notes, [string]$Name) {
  $p = Join-Path $Notes $Name
  if (-not (Test-Path $p)) { return '' }
  return [string](Get-Content -Raw $p)
}

# One read of the state directory, shared by the report body and the verdict line so the two
# cannot disagree about whether the fix was verified.
function Get-ReportFacts([string]$Notes) {
  $ev = Read-StateJson $Notes 'evidence.json'
  $inv = Read-StateJson $Notes 'investigation.json'
  $fix = Read-StateJson $Notes 'fix-summary.json'
  $pr = Read-StateJson $Notes 'pr.json'

  $f = @{}
  $f.reproduced = [bool]($ev -and $ev.reproduced)
  $f.source = if ($ev) { [string]$ev.source } else { '' }
  $f.exitCode = if ($ev) { [string]$ev.exitCode } else { '' }
  $f.classification = if ($ev) { [string]$ev.ciClassification } else { '' }
  $f.excerpt = if ($ev) { [string]$ev.excerpt } else { '' }
  $f.hypothesis = if ($inv) { [string]$inv.hypothesis } else { '' }
  $f.problem = if ($fix) { [string]$fix.problem } else { '' }
  $f.solution = if ($fix) { [string]$fix.solution } else { '' }
  $f.fixSummary = if ($fix) { [string]$fix.fixSummary } else { '' }
  $f.confidence = if ($fix) { [string]$fix.confidence } else { '' }
  $f.attempts = if ($fix) { [string]$fix.attempts } else { '' }
  $f.fixVerified = [bool]($fix -and $fix.verified)
  $f.prUrl = if ($pr) { [string]$pr.prUrl } else { '' }
  $f.patch = Read-StateText $Notes 'fix.patch'
  $f.notebook = Read-StateText $Notes 'notebook.md'
  $f.verify = Read-StateText $Notes 'verify-output.log'
  $f.claudeError = (Read-StateText $Notes 'claude-error.txt').Trim()
  return $f
}

# The notebook is written as a document of its own, so its `##` headings would sit level with
# the report's and break the outline. Push them one deeper, skipping fenced blocks - a `# do the
# thing` comment in a shell snippet is not a heading.
function Format-Nested([string]$Markdown) {
  $fence = $false
  $out = foreach ($line in ($Markdown -split "`n")) {
    if ($line.TrimStart().StartsWith('```')) { $fence = -not $fence; $line }
    elseif (-not $fence -and $line -match '^#{1,5} ') { '#' + $line }
    else { $line }
  }
  return ($out -join "`n")
}

# Slack has no escape inside an inline code span, so a backtick in a test title would close the
# span early and mangle the rest of the line. Strip, as `summarize` does.
function Format-SlackCode([string]$Text) {
  return (([string]$Text) -replace '`', "'" -replace '\s+', ' ').Trim()
}

# The message the upload posts with. Everything else is in the attached file.
function New-ReportVerdict {
  param(
    [Parameter(Mandatory)][hashtable] $Facts,
    [Parameter(Mandatory)][string] $Spec,
    [string] $Title = '',
    [string] $RunUrl = ''
  )
  $parts = @(
    $(if ($Facts.reproduced) { 'reproduced' } else { 'not reproduced' }),
    $(if ($Facts.fixVerified) { 'fix verified' } else { 'no verified fix' }),
    $(if ($Facts.prUrl) { "<$($Facts.prUrl)|draft PR>" } else { 'no PR' })
  )
  $name = Format-SlackCode $Spec
  if ($Title) { $name += " $ReportArrow " + (Format-SlackCode $Title) }
  $line = ':mag: `' + $name + '` - ' + ($parts -join ', ')
  # "no verified fix" alone reads as a failed attempt; a refused API call means no attempt at all.
  if ($Facts.claudeError) {
    $line = ':no_entry: `' + $name + '` - ' + $parts[0] + ', *not investigated: the Claude API refused the call* (' + (Format-SlackCode $Facts.claudeError) + ')'
  }
  if ($RunUrl) { $line += " $ReportDot <$RunUrl|nightly run>" }
  return $line
}

function New-ReportBody {
  param(
    [Parameter(Mandatory)][hashtable] $Facts,
    [Parameter(Mandatory)][string] $Spec,
    [string] $Title = '',
    [string] $TestCommand = '',
    [string] $RunId = '',
    [string] $RunUrl = '',
    [string] $ReportUrl = ''
  )
  $lines = New-Object System.Collections.Generic.List[string]
  function Add-Line([string]$Text = '') { $lines.Add($Text) }
  # Logs come back through the VM's legacy codepage, so Playwright's box-drawing rules land as
  # mojibake and its cursor moves as raw ANSI escapes. Neither means anything to a reader.
  function Add-Fence([string]$Text, [string]$Lang, [int]$Max) {
    if (-not $Text -or -not $Text.Trim()) { Add-Line '_(nothing captured)_'; return }
    $clean = (Get-Tail $Text $Max) -replace "\[[0-9;?]*[a-zA-Z]", '' -replace '[^ -~\t\r\n]', ''
    $clean = ($clean -split "`n" | Where-Object { $_.Trim() }) -join "`n"
    Add-Line ('```' + $Lang)
    Add-Line $clean.TrimEnd()
    Add-Line '```'
  }

  $head = '# ' + $Spec
  if ($Title) { $head += " $ReportArrow " + $Title }
  Add-Line $head
  Add-Line ''

  $meta = @()
  if ($RunUrl) { $meta += "[nightly run]($RunUrl)" }
  if ($ReportUrl) { $meta += "[test report]($ReportUrl)" }
  $meta += $(if ($Facts.reproduced) { 'reproduced' } else { 'not reproduced' })
  $meta += $(if ($Facts.fixVerified) { 'fix verified' } else { 'no verified fix' })
  $meta += $(if ($Facts.prUrl) { "[draft PR]($($Facts.prUrl))" } else { 'no PR' })
  Add-Line ($meta -join " $ReportDot ")
  Add-Line ''
  if ($Facts.claudeError) {
    Add-Line ('> **Not investigated: the Claude API refused the call.** `{0}`' -f (Format-SlackCode $Facts.claudeError))
    Add-Line ''
  }

  Add-Line '## Cause'
  Add-Line ''
  $cause = if ($Facts.problem) { $Facts.problem } elseif ($Facts.hypothesis) { $Facts.hypothesis } else { '' }
  Add-Line $(if ($cause) { $cause } else { '_No cause established; see what was tried below._' })
  Add-Line ''

  Add-Line '## Repro'
  Add-Line ''
  if ($TestCommand) { Add-Fence $TestCommand 'sh' 2000; Add-Line '' }
  $src = if ($Facts.source -eq 'ci') { 'CI history only (the spec was not re-run here)' } else { 're-run on the investigator VM' }
  Add-Line ('- Evidence: {0}, exit code {1}' -f $src, $Facts.exitCode)
  if ($Facts.classification) { Add-Line ('- CI classification: {0}' -f $Facts.classification) }
  Add-Line ''
  Add-Line 'Failure output:'
  Add-Line ''
  Add-Fence $Facts.excerpt 'text' 4000
  Add-Line ''

  Add-Line '## What was tried'
  Add-Line ''
  if ($Facts.notebook.Trim()) { Add-Line (Format-Nested (Get-Tail $Facts.notebook 30000).TrimEnd()) }
  else { Add-Line '_No investigator notebook in state._' }
  Add-Line ''

  Add-Line '## Finding'
  Add-Line ''
  $finding = if ($Facts.solution) { $Facts.solution } elseif ($Facts.fixSummary) { $Facts.fixSummary } elseif ($Facts.hypothesis) { $Facts.hypothesis } else { '' }
  Add-Line $(if ($finding) { $finding } else { '_No fix was attempted._' })
  Add-Line ''
  if ($Facts.patch) {
    # Never claim a pass the phase did not see.
    $verdict = if ($Facts.fixVerified) { 'The spec was re-run with `--retries=0` against the patched build and passed' } else { 'The spec was re-run with `--retries=0` against the patched build and did NOT pass' }
    $conf = if ($Facts.confidence) { $Facts.confidence } else { 'unstated' }
    $tries = if ($Facts.attempts) { $Facts.attempts } else { '1' }
    Add-Line ('{0}. Fixer confidence: **{1}**, on attempt {2}.' -f $verdict, $conf, $tries)
    Add-Line ''
    Add-Line 'Verification output:'
    Add-Line ''
    Add-Fence $Facts.verify 'text' 4000
    Add-Line ''
    Add-Line '## Diff'
    Add-Line ''
    Add-Line '```diff'
    Add-Line (Get-Tail $Facts.patch 20000).TrimEnd()
    Add-Line '```'
    Add-Line ''
  }

  Add-Line '---'
  Add-Line ''
  Add-Line ('Automated e2e investigator, run `{0}`. Full logs and state: bucket `e2e-investigations/{0}/`.' -f $RunId)
  return ($lines -join "`n")
}
