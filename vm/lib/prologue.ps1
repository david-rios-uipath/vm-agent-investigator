# Dot-sourced by run-phase.ps1. Every phase runs the same prologue, so a job may land on any
# VM in the pool: nothing on disk is assumed, everything installed is installed idempotently.

# Literal, not Join-Path: this file is dot-sourced by the selfcheck on non-Windows too, where
# Join-Path validates the C: drive and throws.
$script:VmRoot   = 'C:\vm-agent'
$script:Bin      = 'C:\vm-agent\bin'
$script:NodeBin  = 'C:\vm-agent\node-global'
$script:NodeDir  = 'C:\vm-agent\node'
$script:RepoDir  = 'C:\vm-agent\repo'
# cmd.exe children (Invoke-Cmd, the dev server) get this PATH prefix; keep it in sync with Add-ToolPath.
$script:ToolPath = "$Bin;$NodeBin;$NodeDir"

# Compare whole PATH entries, not substrings: `-like "*C:\vm-agent\node*"` matched
# C:\vm-agent\node-global, so C:\vm-agent\node was never added and a fresh install of node
# passed while `node` stayed not runnable.
function Add-ToolPath {
  New-Item -ItemType Directory -Force -Path $Bin, $NodeBin | Out-Null
  foreach ($d in @($Bin, $NodeBin, $NodeDir)) {
    if (($env:PATH -split ';') -notcontains $d) { $env:PATH = "$d;$env:PATH" }
  }
}

# Returns the tool's version line, or $null if it is absent or broken. Never throws: calling a
# missing command raises CommandNotFoundException, which $ErrorActionPreference = 'Stop' in the
# caller turns terminating - the "install what is missing" branch would never be reached.
# `native.exe | Select-Object -First 1` closes the pipeline and leaves $LASTEXITCODE set even
# on success (FINDINGS-uip.md). Always capture into an array and read the code afterwards.
function Test-Tool([string]$Exe, [string[]]$VersionArgs = @('--version')) {
  if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }
  try { $out = @(& $Exe @VersionArgs 2>&1) } catch { return $null }
  if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0) { return $out[0] }
  return $null
}

function Install-GhRelease([string]$Repo, [string]$AssetPattern, [string]$ExeName) {
  $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'vm-agent' }
  $url = ($rel.assets | Where-Object name -like $AssetPattern).browser_download_url
  if (-not $url) { throw "[ensure] no asset matching $AssetPattern in $Repo" }
  $zip = Join-Path $env:TEMP "$ExeName.zip"
  $dir = Join-Path $env:TEMP $ExeName
  Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $dir -Force
  $found = Get-ChildItem $dir -Recurse -Filter "$ExeName.exe" | Select-Object -First 1
  if (-not $found) { throw "[ensure] $ExeName.exe not in the downloaded archive" }
  Copy-Item $found.FullName $Bin -Force
}

# Latest LTS from nodejs.org, unpacked whole into $NodeDir: node.exe alone is useless, npm and
# corepack live in the zip's node_modules next to it. The standard VM image ships without node.
function Install-Node {
  $lts = (Invoke-RestMethod 'https://nodejs.org/dist/index.json') | Where-Object { $_.lts } | Select-Object -First 1
  if (-not $lts) { throw '[ensure] no LTS entry in nodejs.org index' }
  $name = "node-$($lts.version)-win-x64"
  $zip = Join-Path $env:TEMP "$name.zip"
  Invoke-WebRequest "https://nodejs.org/dist/$($lts.version)/$name.zip" -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $env:TEMP -Force
  if (Test-Path $NodeDir) { Remove-Item $NodeDir -Recurse -Force }
  Move-Item (Join-Path $env:TEMP $name) $NodeDir
}

function Ensure-Tools {
  Add-ToolPath
  $missing = @()

  # git is the one tool bootstrap.ps1 owns (it must exist before this repo can be cloned);
  # only the probe-phase path, which skips the flow's bootstrap, reaches this on a fresh VM.
  if (-not (Test-Tool 'git')) {
    $missing += 'git'
    Write-Output '[ensure] installing git'
    & (Join-Path $PSScriptRoot '..\bootstrap.ps1') -GitOnly
    if (-not (Test-Tool 'git')) { throw '[ensure] git still not runnable after install' }
  }

  if (-not (Test-Tool 'rg')) {
    $missing += 'rg'
    Write-Output '[ensure] installing ripgrep'
    Install-GhRelease 'BurntSushi/ripgrep' '*-x86_64-pc-windows-msvc.zip' 'rg'
    if (-not (Test-Tool 'rg')) { throw '[ensure] rg still not runnable after install' }
  }

  if (-not (Test-Tool 'gh')) {
    $missing += 'gh'
    Write-Output '[ensure] installing gh'
    Install-GhRelease 'cli/cli' '*_windows_amd64.zip' 'gh'
    if (-not (Test-Tool 'gh')) { throw '[ensure] gh still not runnable after install' }
  }

  # ffmpeg turns the verified run's webm into the mp4/gif that GitHub can render in a PR body.
  # Same conversion flow-workbench's scripts/record-demo.sh uses.
  if (-not (Test-Tool 'ffmpeg' @('-version'))) {
    $missing += 'ffmpeg'
    Write-Output '[ensure] installing ffmpeg'
    try { Install-GhRelease 'BtbN/FFmpeg-Builds' 'ffmpeg-master-latest-win64-gpl.zip' 'ffmpeg' }
    catch { Write-Output "[ensure] ffmpeg install failed: $_ (PR videos will be skipped)" }
  }

  if (-not (Test-Tool 'node')) {
    $missing += 'node'
    Write-Output '[ensure] installing node (LTS)'
    Install-Node
    if (-not (Test-Tool 'node')) { throw '[ensure] node still not runnable after install' }
  }
  if (-not (Test-Path (Join-Path $Bin 'pnpm.cmd'))) {
    $missing += 'pnpm-shim'
    Write-Output '[ensure] enabling corepack pnpm shim'
    Invoke-Cmd "corepack enable --install-directory `"$Bin`" pnpm" $VmRoot | ForEach-Object { Write-Output "  $_" }
    if (-not (Test-Path (Join-Path $Bin 'pnpm.cmd'))) { throw '[ensure] corepack produced no pnpm shim' }
  }

  # Claude Code's config dir must be writable by the robot account; %USERPROFILE% is not
  # dependable on a service-run robot, so pin it under the agent root.
  $env:CLAUDE_CONFIG_DIR = Join-Path $VmRoot 'claude-home'
  New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
  if (-not (Test-Tool 'claude')) {
    $missing += 'claude'
    Write-Output '[ensure] installing Claude Code'
    # Through cmd.exe, not PowerShell: npm writes warnings to stderr, and the caller's
    # $ErrorActionPreference = 'Stop' turns native stderr into a terminating error. A warning
    # about install scripts killed the prologue before this was routed through Invoke-Cmd.
    Invoke-Cmd "npm install -g @anthropic-ai/claude-code --prefix `"$NodeBin`"" $VmRoot |
      Select-Object -Last 5 | ForEach-Object { Write-Output "  $_" }
    Add-ToolPath
    if (-not (Test-Tool 'claude')) { throw '[ensure] claude still not runnable after npm install' }
  }

  if ($missing.Count -eq 0) { Write-Output '[ensure] all tools present' }
  else { Write-Output ('[ensure] installed: ' + ($missing -join ', ')) }
  Write-Output ('[ensure] git ' + (Test-Tool 'git') + ' | rg ' + (Test-Tool 'rg') + ' | gh ' + (Test-Tool 'gh') + ' | node ' + (Test-Tool 'node') +
    ' | claude ' + (Test-Tool 'claude') + ' | ffmpeg ' + $(if (Test-Tool 'ffmpeg' @('-version')) { 'ok' } else { 'MISSING' }))
}

# The checkout is a cache, never wiped: fetch and hard-reset onto the branch, keep node_modules,
# and reinstall only when the lockfile actually moved.
function Refresh-Repo([string]$RepoUrl, [string]$Branch) {
  $url = $RepoUrl
  # Only the injected GH_TOKEN asset, never a VM environment variable: nothing on the VM
  # is assumed to persist between jobs.
  if ($env:GH_TOKEN) { $url = $url -replace '^https://', "https://x-access-token:$($env:GH_TOKEN)@" }

  if (Test-Path (Join-Path $RepoDir '.git')) {
    Write-Output "[repo] refreshing $RepoDir"
    git -C $RepoDir remote set-url origin $url
    git -C $RepoDir fetch origin --prune --depth 50 $Branch
    if ($LASTEXITCODE -ne 0) { throw "[repo] git fetch failed with $LASTEXITCODE" }
    $before = git -C $RepoDir rev-parse HEAD
    git -C $RepoDir checkout -B $Branch FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "[repo] git checkout failed with $LASTEXITCODE" }
    git -C $RepoDir reset --hard FETCH_HEAD | Out-Null
    git -C $RepoDir clean -fdx -e node_modules | Out-Null
    $after = git -C $RepoDir rev-parse HEAD
    $lockChanged = $true
    if ($before -eq $after) { $lockChanged = $false }
    else {
      $diff = @(git -C $RepoDir diff --name-only $before $after -- pnpm-lock.yaml package.json)
      $lockChanged = $diff.Count -gt 0
    }
    if (-not $lockChanged -and (Test-Path (Join-Path $RepoDir 'node_modules'))) {
      Write-Output '[repo] lockfile unchanged; skipping install'
    } else {
      Install-Deps
    }
  } else {
    Write-Output "[repo] cloning $Branch"
    git clone --depth 50 --branch $Branch $url $RepoDir
    if ($LASTEXITCODE -ne 0) { throw "[repo] git clone failed with $LASTEXITCODE" }
    Install-Deps
  }
  # Never leave the token in .git/config for later jobs to leak into their own output.
  git -C $RepoDir remote set-url origin $RepoUrl
  Write-Output ('[repo] head ' + (git -C $RepoDir rev-parse --short HEAD))
}

function Install-Deps {
  # .npmrc reads GH_NPM_REGISTRY_TOKEN for @uipath packages on npm.pkg.github.com. Only the
  # injected GH_TOKEN asset exists, so derive it; never read it from the VM environment.
  $env:GH_NPM_REGISTRY_TOKEN = $env:GH_TOKEN
  Write-Output '[repo] pnpm install'
  Invoke-Cmd 'corepack pnpm install --frozen-lockfile --prefer-offline' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] pnpm install failed with $LASTEXITCODE" }
  Invoke-Cmd 'corepack pnpm exec playwright install chromium' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] playwright install failed with $LASTEXITCODE" }
}

# cmd.exe /c "set VAR=value && ..." puts the trailing space into the value; quote the whole
# assignment (FINDINGS-uip.md - it cost a run when E2E_STUDIO_PORT became "3000 ").
function Invoke-Cmd([string]$CommandLine, [string]$WorkingDir = $RepoDir, [hashtable]$Env = @{}) {
  $prefix = "set `"PATH=$ToolPath;%PATH%`""
  foreach ($k in $Env.Keys) { $prefix += " && set `"$k=$($Env[$k])`"" }
  if (-not (Test-Path $WorkingDir)) { New-Item -ItemType Directory -Force -Path $WorkingDir | Out-Null }
  Push-Location $WorkingDir
  # Belt and braces: whatever the caller's preference is, a native command writing to stderr
  # must not become a terminating error here.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & cmd.exe /c "$prefix && $CommandLine" } finally { $ErrorActionPreference = $prev; Pop-Location }
}

function Get-Tail([string]$Text, [int]$Max) {
  if (-not $Text) { return '' }
  if ($Text.Length -le $Max) { return $Text }
  return "[truncated to last $Max chars]`n" + $Text.Substring($Text.Length - $Max)
}

# PowerShell 5.1's `>` redirection writes UTF-16LE and git apply then reports "No valid
# patches in input" (FINDINGS-uip.md). Always write patches through this.
function Write-Utf8Lf([string]$Path, [string]$Text) {
  $lf = [string][char]10
  $t = $Text.TrimStart([char]0xFEFF).Replace([string][char]13 + $lf, $lf)
  if ($t -and -not $t.EndsWith($lf)) { $t += $lf }
  [System.IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# The flow parses this line and nothing else. It must be the last line of stdout.
function Write-Status([hashtable]$Status) {
  $json = ($Status | ConvertTo-Json -Compress -Depth 6)
  # Stdout comes back through a legacy codepage, which turns a U+2014 into bytes ending in a
  # literal quote and breaks JSON.parse in the flow. Keep the line pure ASCII.
  $json = [regex]::Replace($json, '[^\x20-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
  Write-Output ''
  Write-Output "STATUS_JSON=$json"
}

# Turns the newest .webm under $SearchRoot into the mp4/gif pair a PR body can render, in
# $Notes/<BaseName>.{mp4,gif}. Returns the mp4 path, the gif path, or $null when there is
# nothing to show. ffmpeg arguments are flow-workbench's scripts/record-demo.sh, so the output
# matches what the pr-demo skill produces by hand. Both the failing repro and the verified fix
# go through here, which is why the caller names the clip.
function Save-DemoVideo {
  param(
    [Parameter(Mandatory)][string] $SearchRoot,
    [Parameter(Mandatory)][string] $Notes,
    [Parameter(Mandatory)][string] $BaseName,
    # The fix phase mirrors its log into the PR body; the repro phase just prints.
    [scriptblock] $Log = { param($m) Write-Output $m }
  )
  $video = Get-ChildItem $SearchRoot -Recurse -Filter *.webm -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $video) { return $null }

  $webm = Join-Path $Notes "$BaseName.webm"
  Copy-Item $video.FullName $webm -Force
  & $Log "[$BaseName] video saved to state"
  if (-not (Test-Tool 'ffmpeg' @('-version'))) { & $Log "[$BaseName] no ffmpeg on this VM; the PR will have no video"; return $null }

  $mp4 = Join-Path $Notes "$BaseName.mp4"; $gif = Join-Path $Notes "$BaseName.gif"
  Invoke-Cmd ('ffmpeg -y -loglevel error -i "{0}" -vf "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -pix_fmt yuv420p "{1}"' -f $video.FullName, $mp4) $RepoDir | Out-Null
  if (-not (Test-Path $mp4)) { & $Log "[$BaseName] ffmpeg produced no mp4; the PR will have no video"; return $null }
  Invoke-Cmd ('ffmpeg -y -loglevel error -i "{0}" -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer" -loop 0 "{1}"' -f $mp4, $gif) $RepoDir | Out-Null
  & $Log ("[$BaseName] mp4 {0:N1} MB, gif {1:N1} MB" -f ((Get-Item $mp4).Length / 1MB),
    $(if (Test-Path $gif) { (Get-Item $gif).Length / 1MB } else { 0 }))

  # Keep the state archive small: the mp4 supersedes its own source, and a gif too big to
  # attach is dead weight in every later pull.
  Remove-Item $webm -Force -ErrorAction SilentlyContinue
  if ((Test-Path $gif) -and (Get-Item $gif).Length -ge 9MB) {
    & $Log "[$BaseName] gif is over the attachable size; keeping only the mp4"
    Remove-Item $gif -Force -ErrorAction SilentlyContinue
  }
  return $mp4
}
