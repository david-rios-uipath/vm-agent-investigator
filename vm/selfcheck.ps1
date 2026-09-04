# Runnable check for the phase runner's pure logic. No VM, no network, no Orchestrator.
#   pwsh -NoProfile -File vm/selfcheck.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib/prologue.ps1')
. (Join-Path $here 'lib/ci-history.ps1')

function Assert([bool]$Cond, [string]$What) {
  if (-not $Cond) { throw "FAIL: $What" }
  Write-Host "ok  $What"
}

# Get-Tail
Assert ((Get-Tail 'abc' 10) -eq 'abc') 'short text is returned whole'
Assert ((Get-Tail ('x' * 100) 10).EndsWith('x' * 10)) 'long text keeps its tail'
Assert ((Get-Tail $null 10) -eq '') 'null text is empty'

# Write-Utf8Lf: no BOM, LF only, trailing newline. This is the trap that killed git apply.
$tmp = [System.IO.Path]::GetTempFileName()
Write-Utf8Lf $tmp "diff --git a/x b/x`r`nline"
$bytes = [System.IO.File]::ReadAllBytes($tmp)
Assert ($bytes[0] -eq 0x64) 'patch starts with the diff text, not a BOM'
Assert (-not ($bytes -contains 13)) 'patch has no CR bytes'
Assert ($bytes[$bytes.Length - 1] -eq 10) 'patch ends with a newline'
Remove-Item $tmp

# Write-Status must emit exactly one STATUS_JSON= line, last.
$out = @(Write-Status @{ reproduced = $true; exitCode = 1; excerpt = "two`nlines" })
$last = $out[-1]
Assert ($last.StartsWith('STATUS_JSON=')) 'STATUS_JSON is the last line'
Assert (@($out | Where-Object { $_ -like 'STATUS_JSON=*' }).Count -eq 1) 'exactly one STATUS_JSON line'
$parsed = ConvertFrom-Json $last.Substring('STATUS_JSON='.Length)
Assert ($parsed.reproduced -eq $true -and $parsed.exitCode -eq 1) 'status round-trips through JSON'
Assert ($parsed.excerpt -eq "two`nlines") 'embedded newlines survive as JSON escapes'

# Get-LastJson lives in run-phase.ps1; copy of the same expression under test.
function Get-LastJson([string]$Text) {
  if (-not $Text) { return $null }
  $found = [regex]::Matches($Text, '\{[^{}]*\}')
  for ($i = $found.Count - 1; $i -ge 0; $i--) {
    try { return ConvertFrom-Json $found[$i].Value } catch { }
  }
  return $null
}
$j = Get-LastJson 'chatter {"a":1} more {"patchWritten": true, "confidence": "high"}'
Assert ($j.patchWritten -eq $true -and $j.confidence -eq 'high') 'the last JSON object wins'
Assert ($null -eq (Get-LastJson 'no json here')) 'no JSON returns null'
Assert ($null -eq (Get-LastJson '')) 'empty text returns null'

# Repro routing: only an unsettled CI verdict costs a local test run.
foreach ($c in @('regression', 'consistent', 'flaky')) {
  Assert (-not (Test-NeedsRepro @{ classification = $c })) "$c is settled by CI history"
}
foreach ($c in @('unknown', 'absent', 'passing')) {
  Assert (Test-NeedsRepro @{ classification = $c }) "$c needs a local repro"
}

# PR title trimming, as the pr phase does it.
function Get-PrTitle([string]$FixSummary, [string]$Spec) {
  $short = ((($FixSummary -split "`n")[0]).Trim())
  if ($short.Length -gt 60) { $short = $short.Substring(0, 60) -replace '\s+\S*$', '' }
  $short = $short -replace '\s*\([^)]*$', '' -replace '[\s(,;:-]+$', ''
  if ($short) { return "fix: $short (automated investigator)" }
  return "test(e2e): fix $Spec (automated investigator)"
}
Assert ((Get-PrTitle '' 'debug-execution') -eq 'test(e2e): fix debug-execution (automated investigator)') 'empty summary falls back to the spec name'
$t = Get-PrTitle 'Retarget the two copy-path locators at debug-execution.spec.ts (lines 84 and 87) to the new aria-label' 'x'
Assert (-not ($t -match '\($')) 'the title never ends mid-parenthesis'
Assert ($t.EndsWith('(automated investigator)')) 'the title keeps its suffix'
Assert ($t.Length -lt 110) 'the title stays short'

Write-Host ''
Write-Host 'selfcheck passed'
