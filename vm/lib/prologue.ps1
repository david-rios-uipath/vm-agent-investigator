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
    git -C $RepoDir checkout -B $Branch FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "[repo] git checkout failed with $LASTEXITCODE" }
    git -C $RepoDir reset --hard FETCH_HEAD | Out-Null
    # Storage state is a login cache the fixtures regenerate whenever it is invalid; keeping it
    # saves a cold auth per phase. node_modules is likewise a cache (see Test-DepsInstalled).
    git -C $RepoDir clean -fdx -e node_modules -e 'e2e/*.storage-state.json' | Out-Null
    # node_modules is a cache, never trusted on sight: a job killed mid-install leaves a partial
    # tree that looks present. Only a stamp written after a full install, for this exact
    # lockfile, skips the install.
    if (Test-DepsInstalled) {
      Write-Output '[repo] deps already installed for this lockfile; skipping install'
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
  # .npmrc reads GH_NPM_REGISTRY_TOKEN for @uipath packages on npm.pkg.github.com; vm-exec
  # injects it from the asset of the same name (GH_TOKEN alone gets 403 from the registry).
  if (-not $env:GH_NPM_REGISTRY_TOKEN) { throw '[repo] GH_NPM_REGISTRY_TOKEN was not injected; add the Credential asset to the process folder' }
  Write-Output '[repo] pnpm install'
  Invoke-Cmd 'corepack pnpm install --frozen-lockfile --prefer-offline' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] pnpm install failed with $LASTEXITCODE" }
  Invoke-Cmd 'corepack pnpm exec playwright install chromium' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] playwright install failed with $LASTEXITCODE" }
  Set-Content -Path (Deps-Stamp) -Value (Lockfile-Hash) -NoNewline
}

# ------------------------------------------------------------------- vsix projects
# The vsix Playwright projects drive a real VS Code (e2e/vsix/launcher.ts) instead of a browser.
# They need three things the studio projects do not: a home directory this account can write
# (the extension resolves its identity from <home>\.uipath\.auth), that credential file, and the
# extension bundle built from the working tree.
#
# A window is not one of them. Jobs run as LOCAL SERVICE in session 0, where Electron gets no
# window at all - but Playwright attaches over the debug port and records via CDP screencast,
# both of which work there (probed with vm/probes/vsix-cdp.ps1: workbench target present,
# Page.captureScreenshot returns a painted frame).

# `vsix-staging-linux` is not a project the config defines: the platform segment comes from
# CI's E2E_RUNNER_PLATFORM and the host segment from E2E_VSIX_HOST (e2e/config/base-config.ts
# builds the name from all three). Drop both - this VM runs VS Code on Windows, so the bare
# name is the one that resolves here. Studio commands pass through untouched.
function Resolve-TestCommand([string]$TestCommand) {
  return [regex]::Replace($TestCommand,
    '(--project[=\s]+"?)vsix-(alpha|staging)(?:-(?:vscode|cursor))?(?:-(?:linux|macos|windows))?',
    '${1}vsix-$2')
}

function Test-IsVsixCommand([string]$TestCommand) { return $TestCommand -match '--project[=\s]+"?vsix-' }

$script:VsixHome = 'C:\vm-agent\home'

# %USERPROFILE% for LOCAL SERVICE lives under C:\Windows\ServiceProfiles and is not dependable
# (the same reason CLAUDE_CONFIG_DIR is pinned). node's os.homedir() reads it, and both the login
# script and the extension resolve the credential file through it, so point both at one
# directory we know is writable. cmd.exe children inherit these.
function Set-VsixHome {
  New-Item -ItemType Directory -Force -Path $VsixHome | Out-Null
  $env:USERPROFILE = $VsixHome
  $env:HOME = $VsixHome
  Write-Output "[vsix] home = $VsixHome"
}

# @uipath/cli resolves through the repo's .npmrc (GitHub Packages), the same way CI installs it.
function Ensure-UipCli {
  if (Test-Tool 'uip') { return }
  Write-Output '[vsix] installing @uipath/cli'
  Invoke-Cmd "npm install -g --ignore-scripts --userconfig `"$RepoDir\.npmrc`" --prefix `"$NodeBin`" @uipath/cli" $RepoDir |
    Select-Object -Last 5 | ForEach-Object { Write-Output "  $_" }
  Add-ToolPath
  if (-not (Test-Tool 'uip')) { throw '[vsix] uip still not runnable after npm install' }
}

# `uip login --no-browser` prints an authorization URL and waits on a localhost callback; the
# repo's own script drives that URL with a headless Chromium and the shared tester account, then
# writes <home>\.uipath\.auth. Reuse it rather than reimplementing the handshake - it is exactly
# what .github/workflows/playwright-vsix.yml runs. The environment mirrors that workflow, whose
# values are also e2e/config/base-config.ts's alpha defaults.
function Get-VsixEnvironment([string]$TestCommand) {
  if ($TestCommand -match '--project[=\s]+"?vsix-staging') { return 'staging' }
  return 'alpha'
}

function Ensure-VsixAuth([string]$Environment = 'alpha') {
  $auth = Join-Path $VsixHome '.uipath\.auth'
  # One credential file, one identity: a cached login for the other environment is worse than
  # no login, so the stamp forces a re-login when the environment changes.
  $stamp = Join-Path $VsixHome '.uipath\.vm-agent-environment'
  if ((Test-Path $auth) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $Environment)) {
    Write-Output "[vsix] .uipath\.auth already present for $Environment"
    return
  }
  if (-not $env:PLAYWRIGHT_PASSWORD) { throw '[vsix] PLAYWRIGHT_PASSWORD was not injected; add the Secret asset to the process folder' }
  $script = Join-Path $RepoDir '.github\scripts\vsix-interactive-login.mjs'
  if (-not (Test-Path $script)) { throw "[vsix] $script is missing from the checkout" }
  # Same values as .github/workflows/playwright-vsix.yml, which are also base-config.ts's
  # defaults for each region.
  $loginEnv = if ($Environment -eq 'staging') {
    @{ E2E_AUTHORITY = 'https://staging.uipath.com'; E2E_ORGANIZATION = 'ap4ao'; E2E_TENANT = 'euTenant' }
  } else {
    @{ E2E_AUTHORITY = 'https://alpha.uipath.com'; E2E_ORGANIZATION = 'experiencestest'; E2E_TENANT = 'DefaultTenant' }
  }
  $loginEnv['E2E_EMAIL'] = 'uip-experiences-tester@outlook.com'
  Write-Output "[vsix] uip login to $Environment (interactive authorization code, headless browser)"
  $out = @(Invoke-Cmd "node `"$script`"" $RepoDir $loginEnv 2>&1)
  $code = $LASTEXITCODE
  $out | Select-Object -Last 15 | ForEach-Object { Write-Output "  $_" }
  if ($code -ne 0) { throw "[vsix] interactive login exited $code" }
  if (-not (Test-Path $auth)) { throw "[vsix] login reported success but wrote no $auth" }
  Set-Content -Path $stamp -Value $Environment -NoNewline
  Write-Output '[vsix] credential file written'
}

# The bundle FlowEditorProvider activates, built from the working tree - so this is also how a
# patch to product source reaches the verify run, the vsix counterpart of the studio projects'
# locally served MFE. Minutes of webpack, so build once, and never before a patch is applied.
function Build-Vsix {
  Write-Output '[vsix] corepack pnpm --filter=uipath-maestro run package'
  $out = @(Invoke-Cmd 'corepack pnpm --filter=uipath-maestro run package' $RepoDir 2>&1)
  $code = $LASTEXITCODE
  $out | Select-Object -Last 10 | ForEach-Object { Write-Output "  $_" }

  # `scripts/fetch-mfe-assets.mjs` stages the MFE assets through renames. One EPERM there leaves
  # packages/vsix/.mfe-cache in a state every later build trips over - first at rebuildCache's
  # rename, then at stageDestination's - so the failure looks permanent and survives a plain
  # retry. Deleting the cache and building again clears it (verified on the pool VM: two builds
  # failed at those two sites, a third succeeded with nothing else changed). The cache is a
  # download cache, so this costs a re-fetch, not correctness - and the pool's single VM means a
  # poisoned cache would otherwise outlive the job that created it.
  if ($code -ne 0) {
    $cache = Join-Path $RepoDir 'packages\vsix\.mfe-cache'
    if (Test-Path $cache) {
      Write-Output '[vsix] build failed; clearing packages\vsix\.mfe-cache and building once more'
      Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
      $out = @(Invoke-Cmd 'corepack pnpm --filter=uipath-maestro run package' $RepoDir 2>&1)
      $code = $LASTEXITCODE
      $out | Select-Object -Last 10 | ForEach-Object { Write-Output "  $_" }
    }
  }
  if ($code -ne 0) { throw "[vsix] extension build failed with $code" }
}

function Deps-Stamp { Join-Path $RepoDir 'node_modules\.vm-agent-installed' }
function Lockfile-Hash { (Get-FileHash (Join-Path $RepoDir 'pnpm-lock.yaml') -Algorithm SHA256).Hash }
function Test-DepsInstalled {
  $stamp = Deps-Stamp
  (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq (Lockfile-Hash))
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
