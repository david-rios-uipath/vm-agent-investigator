# Proves the Slack file upload in isolation, before any phase depends on it:
#
#   ./probe-script.sh vm/probes/slack-upload.ps1
#
# Sent inline, so it runs your working tree - no push, no pack, no deploy, ~5 minutes. This is
# where a missing `files:write` scope, a placeholder SLACK_TOKEN asset, or an app that was never
# invited to the channel shows up (the last one as `channel_not_found`).
#
# Set $THREAD_TS to a scratch thread's ts before running. Afterwards, check that the file
# appears in-thread with its comment, and that the token is redacted from the job output.
$ErrorActionPreference = 'Continue'

$CHANNEL = 'C0AH25MT3L5'   # #flow-dev-frontend
$THREAD_TS = ''            # <- the ts of a scratch thread in that channel

# probe-script.sh inlines this from the working tree; there is no checkout on the VM.
. vm/lib/prologue.ps1

Write-Output ('[probe] SLACK_TOKEN ' + $(if ($env:SLACK_TOKEN) { "present, $($env:SLACK_TOKEN.Length) chars" } else { 'MISSING - the asset password is empty' }))
if (-not $THREAD_TS) { Write-Output '[probe] $THREAD_TS is empty; Send-SlackFile will skip the upload by design' }

$file = Join-Path $env:TEMP 'slack-upload-probe.md'
Write-Utf8Lf $file "# Upload probe`n`nIf you can read this in the thread, the three-call upload works from the VM.`n"

$posted = Send-SlackFile -Path $file -Channel $CHANNEL -ThreadTs $THREAD_TS `
  -Comment ':mag: upload probe - one message, one attached file' -Title 'upload probe'

Write-Status @{ posted = [bool]$posted; tokenPresent = [bool]$env:SLACK_TOKEN; thread = $THREAD_TS }
