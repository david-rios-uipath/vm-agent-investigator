# Can this robot VM run a headed Electron app?
#
# The vsix Playwright projects drive a real VS Code window (e2e/vsix/launcher.ts). Everything
# else about vsix support is ordinary plumbing; this is the one question that can kill it, so
# ask it before writing any of that plumbing. Downloads VS Code straight from the update
# service - no node, no npm, no repo checkout - launches it headed, and reports whether a
# window actually appeared and whether the desktop can be captured.
#
# Run: ./probe-script.sh vm/probes/vsix-desktop.ps1 10
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar is very slow here

$root = 'C:\vm-agent\vsix-probe'
$app  = Join-Path $root 'vscode'
$code = Join-Path $app 'Code.exe'
$cli  = Join-Path $app 'bin\code.cmd'
$status = [ordered]@{}

function Note([string]$Line) { Write-Output "[vsix-probe] $Line" }

# 1. What kind of session is this?
$status.user = "$env:USERDOMAIN\$env:USERNAME"
$status.userInteractive = [Environment]::UserInteractive
$status.sessionId = (Get-Process -Id $PID).SessionId
$status.osVersion = [Environment]::OSVersion.VersionString
try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $status.formsLoaded = $true
} catch {
  $status.formsLoaded = $false
  Note "System.Windows.Forms did not load: $_"
}
if ($status.formsLoaded) {
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen
  # A session with no desktop reports 0x0 (or throws above).
  $status.screen = if ($screen) { "$($screen.Bounds.Width)x$($screen.Bounds.Height)" } else { 'none' }
} else {
  $status.screen = 'unknown'
}
Note "user=$($status.user) interactive=$($status.userInteractive) session=$($status.sessionId) screen=$($status.screen)"

# 2. VS Code stable, from the update service. Cached across probes.
if (-not (Test-Path $code)) {
  $zip = Join-Path $root 'vscode.zip'
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  Note 'downloading VS Code stable (win32-x64-archive, ~130 MB)'
  Invoke-WebRequest 'https://update.code.visualstudio.com/latest/win32-x64-archive/stable' -OutFile $zip -UseBasicParsing
  Note "downloaded $([int]((Get-Item $zip).Length / 1MB)) MB; expanding"
  Expand-Archive -Path $zip -DestinationPath $app -Force
  Remove-Item $zip -Force
}
$status.vscodeDownloaded = Test-Path $code
if (-not $status.vscodeDownloaded) { throw 'no Code.exe after expanding the archive' }

# Every VS Code invocation gets its own dirs: %USERPROFILE% is not dependable on this account
# (the same reason CLAUDE_CONFIG_DIR is pinned in the runner's prologue).
$udd = Join-Path $root 'user-data'
$ext = Join-Path $root 'extensions'
$ws  = Join-Path $root 'workspace'
New-Item -ItemType Directory -Force -Path $udd, $ext, $ws | Out-Null
'{ "id": "probe" }' | Set-Content (Join-Path $ws 'probe.json') -Encoding utf8

# 3. The CLI path first - it is the cheap half of the answer. Electron still starts here, so a
#    failure means no Electron at all, not merely no window.
Note 'code.cmd --version'
$verOut = & cmd.exe /c "`"$cli`" --version --user-data-dir `"$udd`" --extensions-dir `"$ext`" 2>&1"
$status.cliExit = $LASTEXITCODE
$status.cliOutput = ($verOut | Select-Object -First 5) -join ' | '
Note "exit $($status.cliExit): $($status.cliOutput)"

# 4. The real question: a headed window.
Note 'launching VS Code headed'
$proc = Start-Process -FilePath $code -PassThru -ArgumentList @(
  '--new-window', $ws,
  '--user-data-dir', $udd, '--extensions-dir', $ext,
  '--disable-updates', '--disable-telemetry', '--disable-workspace-trust'
)
$win = $null
foreach ($i in 1..60) {
  Start-Sleep -Seconds 2
  # Electron spawns a process tree; the window belongs to whichever child owns it.
  $win = Get-Process -Name 'Code' -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($win) { break }
  if ($proc.HasExited) { break }
}
$status.processExited = $proc.HasExited
$status.exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
$status.windowAppeared = [bool]$win
$status.windowTitle = if ($win) { $win.MainWindowTitle } else { '' }
Note "window=$($status.windowAppeared) title='$($status.windowTitle)' exited=$($status.processExited)"

# 5. Can the desktop be captured? A disconnected/headless session typically hands back a
#    uniformly black bitmap, which is also what Playwright's screenshots would be worth.
$status.captureOk = $false
$status.nonBlackPct = 0
if ($status.formsLoaded -and $status.screen -ne 'none') {
  try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    # Sampled, not per-pixel: GetPixel over 2M pixels takes minutes in PowerShell.
    $lit = 0; $n = 0
    for ($y = 0; $y -lt $b.Height; $y += 20) {
      for ($x = 0; $x -lt $b.Width; $x += 20) {
        $n++
        $p = $bmp.GetPixel($x, $y)
        if ($p.R + $p.G + $p.B -gt 30) { $lit++ }
      }
    }
    $shot = Join-Path $root 'desktop.png'
    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $status.captureOk = $true
    $status.nonBlackPct = [math]::Round(100 * $lit / [math]::Max($n, 1), 1)
    Note "captured $($b.Width)x$($b.Height), $($status.nonBlackPct)% non-black, saved to $shot"
  } catch {
    Note "screen capture failed: $_"
  }
}

Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# A window plus a lit desktop means the vsix projects have somewhere to run.
$status.verdict = if ($status.windowAppeared -and $status.nonBlackPct -gt 1) { 'desktop-ok' }
                  elseif ($status.windowAppeared) { 'window-but-blank-capture' }
                  elseif ($status.cliExit -eq 0) { 'electron-runs-no-window' }
                  else { 'no-electron' }
Note "verdict: $($status.verdict)"

# Same one-line contract the phase runner uses, so probe-script.sh can parse it.
$json = ($status | ConvertTo-Json -Compress -Depth 4)
$esc = ($json.ToCharArray() | ForEach-Object {
  if ([int]$_ -gt 127) { '\u{0:x4}' -f [int]$_ } else { $_ }
}) -join ''
Write-Output "STATUS_JSON=$esc"
