<#
  Installs everything in requirements.json. Safe to run again: anything already present is skipped.

  Run from this folder:
    powershell -ExecutionPolicy Bypass -File install.ps1               # required tools
    powershell -ExecutionPolicy Bypass -File install.ps1 -Optional     # also optional tools
    powershell -ExecutionPolicy Bypass -File install.ps1 -Only sadak   # only tools for one project (plus 'all')
    powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun       # show what would happen
#>
param(
    [switch]$Optional,
    [string]$Only,
    [switch]$DryRun,
    [switch]$SkipGitSetup
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $here 'requirements.json') -Raw | ConvertFrom-Json
$results = New-Object System.Collections.Generic.List[object]

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Result($name, $status, $detail) { $results.Add([pscustomobject]@{ Tool = $name; Status = $status; Detail = $detail }) }

function Refresh-Path {
    # Newly installed tools are on the machine PATH but not yet in this session's PATH.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Wanted($tool) {
    if ($tool.optional -and -not $Optional) { return $false }
    if ($Only) { return ($tool.for -contains 'all') -or ($tool.for -contains $Only) }
    return $true
}

# ------------------------------------------------------------------ winget packages

function Install-Winget($tool) {
    $listed = winget list --id $tool.id --exact --accept-source-agreements 2>$null | Select-String -SimpleMatch $tool.id
    if ($listed) { Say "  $($tool.name): already installed"; Result $tool.name 'skipped' 'already installed'; return }
    if ($DryRun) { Say "  $($tool.name): would install winget package $($tool.id)" 'Cyan'; Result $tool.name 'dry run' $tool.id; return }
    Say "  $($tool.name): installing..." 'Cyan'
    winget install --id $tool.id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { Result $tool.name 'FAILED' "winget exit code $LASTEXITCODE"; return }
    Refresh-Path
    Result $tool.name 'installed' $tool.id
}

# ------------------------------------------------------------------ portable zips

function Resolve-Source($source) {
    # Returns @{ Url; Sha256; Version }. Sha256 is $null when the publisher provides none.
    $kind, $version = $source -split ':', 2
    switch ($kind) {
        'adoptium' {
            $api = "https://api.adoptium.net/v3/assets/latest/$version/hotspot?os=windows&architecture=x64&image_type=jdk&vendor=eclipse"
            $asset = (Invoke-RestMethod $api)[0]
            return @{ Url = $asset.binary.package.link; Sha256 = $asset.binary.package.checksum; Version = $asset.version.semver }
        }
        'postgres' {
            # EnterpriseDB publishes the Windows binaries zips; the first link after "Version 17.x" is Windows x86-64.
            $page = (Invoke-WebRequest 'https://www.enterprisedb.com/download-postgresql-binaries' -UseBasicParsing).Content
            $m = [regex]::Match($page, "Version\s*(?:<[^>]+>\s*)*($version\.\d+)(?s:.*?)getfile\.jsp\?fileid=(\d+)")
            if (-not $m.Success) { throw "Could not find PostgreSQL $version on the EnterpriseDB downloads page" }
            return @{ Url = "https://sbp.enterprisedb.com/getfile.jsp?fileid=$($m.Groups[2].Value)"; Sha256 = $null; Version = $m.Groups[1].Value }
        }
        'url' { return @{ Url = $version; Sha256 = $null; Version = '' } }
        default { throw "Unknown source type '$kind'" }
    }
}

function Install-Zip($tool) {
    $target = $tool.to
    if ($tool.check -and (Test-Path (Join-Path $target $tool.check))) {
        Say "  $($tool.name): already in $target"; Result $tool.name 'skipped' "already in $target"; return
    }
    $src = Resolve-Source $tool.source
    if ($tool.sha256) { $src.Sha256 = $tool.sha256 }
    if ($DryRun) { Say "  $($tool.name): would download $($src.Version) to $target" 'Cyan'; Result $tool.name 'dry run' $src.Url; return }

    $work = Join-Path $env:TEMP ("setup-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $work | Out-Null
    try {
        $zip = Join-Path $work 'download.zip'
        Say "  $($tool.name): downloading $($src.Version)..." 'Cyan'
        Invoke-WebRequest $src.Url -OutFile $zip -UseBasicParsing
        $detail = $src.Version
        if ($src.Sha256) {
            $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
            if ($hash -ne $src.Sha256.ToUpper()) { throw "Checksum mismatch for $($tool.name); download discarded" }
            $detail += ', checksum verified'
        } else {
            $detail += ', no published checksum'
        }
        $out = Join-Path $work 'out'
        Expand-Archive $zip -DestinationPath $out -Force
        # Most zips wrap everything in one top folder; install its contents directly into the target.
        $items = Get-ChildItem $out
        $root = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $out }
        New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
        if (Test-Path $target) { throw "$target exists but does not look complete; move it aside and run again" }
        Move-Item $root $target
        foreach ($r in @($tool.remove)) {
            if ($r -and (Test-Path (Join-Path $target $r))) { Remove-Item (Join-Path $target $r) -Recurse -Force -Confirm:$false }
        }
        Result $tool.name 'installed' "$detail -> $target"
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
    }
}

# ------------------------------------------------------------------ git identity and sign-in

function Setup-Git {
    Refresh-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Result 'Git setup' 'skipped' 'git not installed'; return }
    $g = $req.git
    if ($DryRun) { Say "  Git: would set user $($g.name) <$($g.email)>, branch $($g.defaultBranch), credential manager" 'Cyan'; Result 'Git setup' 'dry run' ''; return }
    git config --global user.name $g.name
    git config --global user.email $g.email
    git config --global init.defaultBranch $g.defaultBranch
    git config --global credential.helper manager
    git config --global core.autocrlf true
    Say "  Git: identity set to $($g.name) <$($g.email)>, sign-in through Git Credential Manager" 'Green'
    $answer = Read-Host '  Sign in to GitHub now? A browser window opens. (y/n)'
    if ($answer -match '^[yY]') {
        git credential-manager github login
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $ghAnswer = Read-Host '  Also sign in the GitHub CLI (gh)? (y/n)'
            if ($ghAnswer -match '^[yY]') { gh auth login --web --git-protocol https }
        }
        Result 'Git setup' 'done' 'identity set, signed in'
    } else {
        Result 'Git setup' 'done' 'identity set; you will be asked to sign in on first push or clone'
    }
}

# ------------------------------------------------------------------ run

# ------------------------------------------------------------------ list checks
# Refuse to run on a list with duplicates or missing fields, so a dry run catches them before a push.
$problems = @()
$problems += $req.tools | Where-Object { $_.type -eq 'winget' } | Group-Object { $_.id.ToLower() } | Where-Object Count -gt 1 |
    ForEach-Object { "winget id '$($_.Name)' is listed $($_.Count) times; merge them and combine their 'for' lists" }
$problems += $req.tools | Where-Object { $_.type -eq 'zip' } | Group-Object { $_.to.ToLower().TrimEnd('\') } | Where-Object Count -gt 1 |
    ForEach-Object { "install folder '$($_.Name)' is used by $($_.Count) entries" }
$problems += $req.tools | Group-Object { $_.name.ToLower() } | Where-Object Count -gt 1 |
    ForEach-Object { "name '$($_.Name)' is listed $($_.Count) times" }
foreach ($t in $req.tools) {
    if (-not $t.for -or @($t.for).Count -eq 0) { $problems += "'$($t.name)' has an empty 'for' list" }
    if ($t.type -eq 'winget' -and -not $t.id) { $problems += "'$($t.name)' is a winget entry without an 'id'" }
    if ($t.type -eq 'zip' -and (-not $t.to -or -not $t.check -or -not $t.source)) { $problems += "'$($t.name)' is a zip entry missing 'source', 'to' or 'check'" }
    if (@($t.for) | Group-Object | Where-Object Count -gt 1) { $problems += "'$($t.name)' lists the same project twice in 'for'" }
}
if ($problems) {
    Say "requirements.json has problems; nothing was installed:" 'Red'
    $problems | ForEach-Object { Say "  - $_" 'Red' }
    exit 2
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say 'winget is missing. Install "App Installer" from the Microsoft Store, then run this again.' 'Red'
    exit 1
}
Say "`nInstalling tools$(if ($Only) { " for $Only" })$(if ($DryRun) { ' (dry run)' })`n" 'White'
foreach ($tool in $req.tools) {
    if (-not (Wanted $tool)) { continue }
    try {
        switch ($tool.type) {
            'winget' { Install-Winget $tool }
            'zip' { Install-Zip $tool }
            default { Result $tool.name 'FAILED' "unknown type '$($tool.type)'" }
        }
    } catch {
        Say "  $($tool.name): $($_.Exception.Message)" 'Red'
        Result $tool.name 'FAILED' $_.Exception.Message
    }
}
if (-not $SkipGitSetup) { Say ''; Setup-Git }

Say "`nSummary" 'White'
$results | Format-Table -AutoSize -Wrap
if ($results | Where-Object Status -eq 'FAILED') { exit 1 }
