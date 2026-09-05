# One runnable check for New-PrBody: fake state in, rendered body out.
$vm = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $vm 'lib/prologue.ps1')
. (Join-Path $vm 'lib/pr-body.ps1')

$notes = Join-Path ([System.IO.Path]::GetTempPath()) ('prbody-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $notes | Out-Null
Set-Content (Join-Path $notes 'fix-summary.json') (@{
  title = 'Match JsonTree text rendering in debug spec'
  problem = 'The debug panel splits JSON values across text nodes, so the exact-text locator never matches.'
  solution = 'Match the value with a row-scoped substring locator instead of exact text.'
  fixSummary = 'Swapped getByText(exact) for a row-scoped hasText filter in two assertions. The renderer emits `"key"` and `: value` as siblings.'
  confidence = 'high'; attempts = 2; verified = $true
} | ConvertTo-Json)
Set-Content (Join-Path $notes 'evidence.json') (@{
  source = 'vm'; exitCode = 1; classification = 'regression'
  firstFailSha = 'abc1234'; lastPassSha = 'def5678'
  excerpt = "Error: expect(locator).toBeVisible() failed`nat e2e/specs/debug/debug-execution.spec.ts:84"
} | ConvertTo-Json)
Set-Content (Join-Path $notes 'investigation.json') (@{ complete = $true; hypothesis = 'fallback hypothesis' } | ConvertTo-Json)
Set-Content (Join-Path $notes 'notebook.md') "## Pass 1`nHypothesis: text nodes are split`nRuled out: apollo-react bump - `$env:X and ``backticks`` survive verbatim`n"
Set-Content (Join-Path $notes 'verify-output.log') ("[verify] " + [char]0x1b + "[1A" + [char]0x1b + "[2K1 passed " + [char]0x2500 + [char]0x2500 + [char]0x2500 + "`n`n[verify] test exit 0")

$body = New-PrBody $notes 'run-42' 'debug-execution' @("3`t1`te2e/specs/debug/debug-execution.spec.ts") 

$fail = @()
foreach ($needle in '## Problem', 'row-scoped hasText filter', '## Solution', 'splits JSON values', 'row-scoped substring locator',
  '<summary>How it failed</summary>', '- CI classification: regression', 'Failing since `abc1234`, last green `def5678`',
  '- `e2e/specs/debug/debug-execution.spec.ts` (+3/-1)', 'confidence: **high**, on attempt 2',
  '<summary>Investigation notebook', 'Ruled out: apollo-react bump', '$env:X', 'run `run-42`',
  '[verify] 1 passed') {
  # -like treats a backtick as its escape char, so compare literally.
  if (-not $body.Contains($needle)) { $fail += "missing: $needle" }
}
# details blocks must balance, and markdown inside them needs the blank line after <summary>
$open = ([regex]::Matches($body, '<details>')).Count
$close = ([regex]::Matches($body, '</details>')).Count
if ($open -ne 3 -or $close -ne 3) { $fail += "details blocks: $open open / $close close" }
if ($body -match '<summary>[^\n]*</summary>\n[^\n]') { $fail += 'no blank line after a <summary>' }
if ($body -match '\{\{|\$\(') { $fail += 'unsubstituted placeholder' }
# the fenced logs must survive the codepage scrub without escapes or mojibake, and blank
# lines inside a fence are dropped so the block stays tight
if ($body -match [char]0x1b) { $fail += 'ANSI escape left in the body' }
if ($body -match '[^\u0000-\u007f]') { $fail += 'non-ASCII left in a fenced log' }

# an unverified fix must not claim a pass
$notes2 = Join-Path ([System.IO.Path]::GetTempPath()) ('prbody-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $notes2 | Out-Null
Set-Content (Join-Path $notes2 'fix-summary.json') (@{ problem = 'p'; solution = 's'; fixSummary = 'f'; confidence = 'low'; attempts = 3; verified = $false } | ConvertTo-Json)
$unverified = New-PrBody $notes2 'run-43' 'some' @()
if (-not $unverified.Contains('did NOT pass')) { $fail += 'unverified body claims a pass' }
Remove-Item $notes2 -Recurse -Force

Remove-Item $notes -Recurse -Force
if ($fail) { $fail | ForEach-Object { Write-Output "FAIL $_" }; exit 1 }
Write-Output 'PASS pr-body renders'
Write-Output '----- rendered -----'
Write-Output $body
