# First thing the flow runs on a VM. It runs BEFORE the runner repo exists there, so it cannot
# dot-source vm/lib/prologue.ps1: the flow fetches this one file by raw URL (no git needed),
# and this file installs MinGit the same way Ensure-Tools installs everything else (zip into a
# user-writable dir under C:\vm-agent, prepend to the process PATH), then clones the runner.
# Ensure-Tools calls it with -GitOnly so probe-phase.sh, which skips the flow, gets git too.
param(
  [string]$RunnerRepoUrl,
  [string]$Ref = 'master',
  [string]$Runner = 'C:\vm-agent\runner',
  [switch]$GitOnly
)
# 'Continue', not 'Stop': git writes progress to stderr, which 'Stop' turns into a terminating error.
$ErrorActionPreference = 'Continue'
$GitDir = 'C:\vm-agent\git'

function Install-MinGit {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'vm-agent' } -ErrorAction Stop
  $asset = $rel.assets | Where-Object { $_.name -like 'MinGit-*-64-bit.zip' -and $_.name -notlike '*busybox*' } | Select-Object -First 1
  if (-not $asset) { throw '[bootstrap] no MinGit 64-bit asset in the latest git-for-windows release' }
  $zip = Join-Path $env:TEMP 'mingit.zip'
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -ErrorAction Stop
  if (Test-Path $GitDir) { Remove-Item $GitDir -Recurse -Force }
  Expand-Archive $zip -DestinationPath $GitDir -Force
}

$gitCmd = Join-Path $GitDir 'cmd'
if (($env:PATH -split ';') -notcontains $gitCmd) { $env:PATH = "$gitCmd;$env:PATH" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Output '[bootstrap] installing MinGit'
  Install-MinGit
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '[bootstrap] git still not runnable after install' }
}
Write-Output ('[bootstrap] ' + (git --version))
if ($GitOnly) { exit 0 }

if (-not $RunnerRepoUrl) { throw '[bootstrap] RunnerRepoUrl is empty; nothing to clone' }
$url = $RunnerRepoUrl
if ($env:GIT_TOKEN) { $url = $url -replace '^https://', "https://x-access-token:$($env:GIT_TOKEN)@" }
if (-not (Test-Path "$Runner\.git")) {
  git clone --depth 1 $url $Runner
  if ($LASTEXITCODE -ne 0) { throw '[bootstrap] clone of the runner repo failed' }
}
git -C $Runner remote set-url origin $url
git -C $Runner fetch --depth 1 origin $Ref
if ($LASTEXITCODE -ne 0) { throw '[bootstrap] fetch of the runner repo failed' }
git -C $Runner checkout -q FETCH_HEAD
# Never leave the token in .git/config for later jobs to leak into their own output.
git -C $Runner remote set-url origin $RunnerRepoUrl
Write-Output "[bootstrap] runner at $(git -C $Runner rev-parse --short HEAD)"
exit 0
