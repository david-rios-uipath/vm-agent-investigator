# Dot-sourced by run-phase.ps1. Every phase runs the same prologue, so a job may land on any
# VM in the pool: nothing on disk is assumed, everything installed is installed idempotently.

# Literal, not Join-Path: this file is dot-sourced by the selfcheck on non-Windows too, where
# Join-Path validates the C: drive and throws.
$script:VmRoot   = 'C:\vm-agent'
$script:Bin      = 'C:\vm-agent\bin'
$script:NodeBin  = 'C:\vm-agent\node-global'
$script:RepoDir  = 'C:\vm-agent\repo'

function Add-ToolPath {
  New-Item -ItemType Directory -Force -Path $Bin, $NodeBin | Out-Null
  foreach ($d in @($Bin, $NodeBin)) {
    if ($env:PATH -notlike "*$d*") { $env:PATH = "$d;$env:PATH" }
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

function Ensure-Tools {
  Add-ToolPath
  $missing = @()

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

  if (-not (Test-Tool 'node')) { throw '[ensure] node is not on PATH; this VM is not provisioned' }
  if (-not (Test-Path (Join-Path $Bin 'pnpm.cmd'))) {
    $missing += 'pnpm-shim'
    Write-Output '[ensure] enabling corepack pnpm shim'
    corepack enable --install-directory $Bin pnpm
    if (-not (Test-Path (Join-Path $Bin 'pnpm.cmd'))) { throw '[ensure] corepack produced no pnpm shim' }
  }

  # Claude Code's config dir must be writable by the robot account; %USERPROFILE% is not
  # dependable on a service-run robot, so pin it under the agent root.
  $env:CLAUDE_CONFIG_DIR = Join-Path $VmRoot 'claude-home'
  New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
  if (-not (Test-Tool 'claude')) {
    $missing += 'claude'
    Write-Output '[ensure] installing Claude Code'
    npm install -g @anthropic-ai/claude-code --prefix $NodeBin 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Output "  $_" }
    Add-ToolPath
    if (-not (Test-Tool 'claude')) { throw '[ensure] claude still not runnable after npm install' }
  }

  if ($missing.Count -eq 0) { Write-Output '[ensure] all tools present' }
  else { Write-Output ('[ensure] installed: ' + ($missing -join ', ')) }
  Write-Output ('[ensure] rg ' + (Test-Tool 'rg') + ' | gh ' + (Test-Tool 'gh') + ' | node ' + (Test-Tool 'node') + ' | claude ' + (Test-Tool 'claude'))
}

# The checkout is a cache, never wiped: fetch and hard-reset onto the branch, keep node_modules,
# and reinstall only when the lockfile actually moved.
function Refresh-Repo([string]$RepoUrl, [string]$Branch) {
  $url = $RepoUrl
  if ($env:GIT_TOKEN) { $url = $url -replace '^https://', "https://x-access-token:$($env:GIT_TOKEN)@" }

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
  Write-Output '[repo] pnpm install'
  Invoke-Cmd 'corepack pnpm install --frozen-lockfile --prefer-offline' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] pnpm install failed with $LASTEXITCODE" }
  Invoke-Cmd 'corepack pnpm exec playwright install chromium' $RepoDir
  if ($LASTEXITCODE -ne 0) { throw "[repo] playwright install failed with $LASTEXITCODE" }
}

# cmd.exe /c "set VAR=value && ..." puts the trailing space into the value; quote the whole
# assignment (FINDINGS-uip.md - it cost a run when E2E_STUDIO_PORT became "3000 ").
function Invoke-Cmd([string]$CommandLine, [string]$WorkingDir = $RepoDir, [hashtable]$Env = @{}) {
  $prefix = "set `"PATH=$Bin;$NodeBin;%PATH%`""
  foreach ($k in $Env.Keys) { $prefix += " && set `"$k=$($Env[$k])`"" }
  Push-Location $WorkingDir
  try { & cmd.exe /c "$prefix && $CommandLine" } finally { Pop-Location }
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
  Write-Output ''
  Write-Output "STATUS_JSON=$json"
}
