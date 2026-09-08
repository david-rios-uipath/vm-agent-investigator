# Follow-up to vsix-desktop.ps1, which found: session 0, no window, no desktop capture.
#
# Playwright never touches the VS Code window through the screen - `e2e/vsix/launcher.ts`
# attaches over CDP on a debug port, and recording goes through CDP screencast too
# (playwright.config.ts:110). So the question is not "is there a visible window" but "does
# Electron expose a workbench target". If it does, vsix can run on this pool as-is.
#
# Run: ./probe-script.sh vm/probes/vsix-cdp.ps1 10
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'C:\vm-agent\vsix-probe'
$code = Join-Path $root 'vscode\Code.exe'
$status = [ordered]@{}
function Note([string]$Line) { Write-Output "[vsix-cdp] $Line" }

if (-not (Test-Path $code)) { throw "no VS Code at $code - run vsix-desktop.ps1 first" }

$udd = Join-Path $root 'user-data'
$ext = Join-Path $root 'extensions'
$ws  = Join-Path $root 'workspace'
New-Item -ItemType Directory -Force -Path $udd, $ext, $ws | Out-Null

$port = 9333
$status.port = $port
Note "launching VS Code with --remote-debugging-port=$port"
$proc = Start-Process -FilePath $code -PassThru -ArgumentList @(
  '--new-window', $ws,
  '--user-data-dir', $udd, '--extensions-dir', $ext,
  '--disable-updates', '--disable-telemetry', '--disable-workspace-trust',
  "--remote-debugging-port=$port"
)

# The port opens before the workbench finishes loading, so poll for a titled page target
# rather than for the first response.
$targets = @()
foreach ($i in 1..45) {
  Start-Sleep -Seconds 2
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 3
    $targets = @($r.Content | ConvertFrom-Json)
    if ($targets.Count -gt 0) { break }
  } catch { }
  if ($proc.HasExited) { Note "process exited early, code $($proc.ExitCode)"; break }
}

$status.processExited = $proc.HasExited
$status.targetCount = $targets.Count
$status.targets = @($targets | ForEach-Object { "$($_.type): $($_.title)" })
foreach ($t in $status.targets) { Note "target $t" }

# The workbench itself is the page Playwright attaches to; a webview target only exists once a
# custom editor mounts, which this empty workspace has no reason to do.
$status.workbenchTarget = [bool](@($targets | Where-Object { $_.type -eq 'page' -and $_.title }).Count)

# Screencast is how the vsix specs record video, and it runs entirely over CDP - so prove the
# renderer paints without a desktop by asking it for one frame.
$status.screencastFrame = $false
if ($status.workbenchTarget) {
  $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.title })[0]
  try {
    # No Add-Type: ClientWebSocket ships in .NET Framework, and asking for the assembly by
    # name fails on Windows PowerShell 5.1 ('one or more required assemblies are missing').
    $sock = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource 20000
    $sock.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $cts.Token).Wait()
    $msg = '{"id":1,"method":"Page.captureScreenshot","params":{"format":"png"}}'
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $sock.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, $cts.Token).Wait()
    $buf = New-Object byte[] 65536
    $sb = New-Object System.Text.StringBuilder
    do {
      $res = $sock.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token)
      $res.Wait()
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Result.Count))
    } while (-not $res.Result.EndOfMessage)
    $reply = $sb.ToString()
    # A painted frame is tens of KB of base64; an empty surface returns a few hundred bytes.
    $status.screencastBytes = $reply.Length
    $status.screencastFrame = $reply -match '"data"' -and $reply.Length -gt 5000
    Note "CDP screenshot reply $($reply.Length) chars"
    $sock.Dispose()
  } catch {
    Note "CDP screenshot failed: $_"
  }
}

Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$status.verdict = if ($status.screencastFrame) { 'cdp-ok-renderer-paints' }
                  elseif ($status.workbenchTarget) { 'cdp-target-but-no-frame' }
                  elseif ($status.targetCount -gt 0) { 'cdp-up-no-workbench' }
                  else { 'no-cdp' }
Note "verdict: $($status.verdict)"

$json = ($status | ConvertTo-Json -Compress -Depth 4)
$esc = ($json.ToCharArray() | ForEach-Object {
  if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } else { $_ }
}) -join ''
Write-Output "STATUS_JSON=$esc"
