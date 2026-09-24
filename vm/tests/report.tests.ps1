# One runnable check for the report's Claude-refusal wording: fake state in, verdict and body out.
$vm = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $vm 'lib/prologue.ps1')
. (Join-Path $vm 'lib/report.ps1')

$notes = Join-Path ([System.IO.Path]::GetTempPath()) ('report-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $notes | Out-Null
Set-Content (Join-Path $notes 'evidence.json') (@{ reproduced = $true; source = 'vm'; exitCode = 1; excerpt = 'Error: boom' } | ConvertTo-Json)

$fail = @()
$plain = New-ReportVerdict -Facts (Get-ReportFacts $notes) -Spec 'connectors' -Title 'persists'
if ($plain -notmatch '^:mag: .* - reproduced, no verified fix, no PR$') { $fail += "plain verdict: $plain" }

$refusal = 'API Error: 400 You have reached your specified workspace API usage limits.'
Set-Content (Join-Path $notes 'claude-error.txt') $refusal
$facts = Get-ReportFacts $notes
$verdict = New-ReportVerdict -Facts $facts -Spec 'connectors' -Title 'persists'
if ($verdict -notmatch '^:no_entry: `connectors .* persists` - reproduced, \*not investigated: the Claude API refused the call\*') { $fail += "refused verdict: $verdict" }
if (-not $verdict.Contains($refusal)) { $fail += 'refused verdict lacks the API message' }
if ((New-ReportBody -Facts $facts -Spec 'connectors') -notmatch 'Not investigated: the Claude API refused the call') { $fail += 'body lacks the refusal line' }

# Write-Status repeats the refusal on every phase's status line.
$status = Write-Status @{ fixVerified = $false } | Select-Object -Last 1
if ($status -notmatch '"claudeError":"API Error: 400') { $fail += "status: $status" }

Remove-Item -Recurse -Force $notes
if ($fail) { $fail | ForEach-Object { Write-Output "FAIL $_" }; exit 1 }
Write-Output 'report ok'
