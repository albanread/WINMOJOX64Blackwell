# install.ps1 -- put a release where the tools expect to find it.
#
# The zip needs no installer: unpack it anywhere and the first thing you run
# repoints it at itself. This exists for the other half of the contract --
# `%LOCALAPPDATA%\WinMojo\current`, which is the second place Griddle's
# toolchain lookup checks, and which lets several versions sit side by side
# with one of them current.
#
#   .\install.ps1                      install this package for the current user
#   .\install.ps1 -Zip <path>          unpack an archive and install that
#   .\install.ps1 -Root D:\WinMojo     somewhere other than %LOCALAPPDATA%
#   .\install.ps1 -List                what is installed, and which is current
#   .\install.ps1 -Uninstall 1a2b3c4   remove one version
#
# Per-user by design: no elevation, no registry, no service, nothing outside
# one directory. Uninstalling is deleting that directory, and this script says
# so rather than pretending to be more than a copy.

[CmdletBinding()]
param(
    [string]$Zip,
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'WinMojo'),
    [string]$Version,
    [switch]$List,
    [switch]$Uninstall,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'

function Get-Junction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType) { return $item.Target | Select-Object -First 1 }
    return $null
}

# ---- listing ---------------------------------------------------------------
if ($List) {
    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Host "Nothing installed under $Root"
        exit 0
    }
    $current = Get-Junction (Join-Path $Root 'current')
    Get-ChildItem -LiteralPath $Root -Directory |
        Where-Object { $_.Name -ne 'current' } |
        ForEach-Object {
            $mark = if ($current -and ($current.TrimEnd('\') -eq $_.FullName.TrimEnd('\'))) { '*' } else { ' ' }
            $size = (Get-ChildItem -LiteralPath $_.FullName -File -Recurse |
                     Measure-Object -Property Length -Sum).Sum
            '{0} {1}  ({2:N0} MiB)' -f $mark, $_.Name, ($size / 1MB)
        }
    if ($current) { Write-Host "`ncurrent -> $current" }
    exit 0
}

# ---- removing --------------------------------------------------------------
if ($Uninstall) {
    if (-not $Version) { throw "Which version? Pass -Version, or -List to see them." }
    $target = Join-Path $Root $Version
    if (-not (Test-Path -LiteralPath $target)) { throw "Not installed: $Version" }
    $current = Get-Junction (Join-Path $Root 'current')
    if ($current -and ($current.TrimEnd('\') -eq $target.TrimEnd('\'))) {
        # The junction is removed with Remove-Item on the link itself, which
        # deletes the link and not what it points at -- but only when the
        # target still exists, so it goes first.
        Remove-Item -LiteralPath (Join-Path $Root 'current') -Force -Recurse
        Write-Host "current was pointing at this version; the pointer is gone too."
    }
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed $target"
    exit 0
}

# ---- what are we installing ------------------------------------------------
$staging = $null
if ($Zip) {
    if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "No such archive: $Zip" }
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('winmojo-unpack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Host "Unpacking $Zip ..."
    Expand-Archive -LiteralPath $Zip -DestinationPath $staging -Force
    $source = $staging
} else {
    # The package this script is sitting in.
    $source = $PSScriptRoot
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'bin\mojo.exe'))) {
    throw "That does not look like a WinMojo package: no bin\mojo.exe under $source"
}

if (-not $Version) {
    $revisionFile = Join-Path $source 'BUILD-REVISION.txt'
    if (Test-Path -LiteralPath $revisionFile) {
        $Version = (Get-Content -LiteralPath $revisionFile -Raw).Trim()
    }
    if (-not $Version) { $Version = 'unversioned' }
}

$target = Join-Path $Root $Version
if ((Test-Path -LiteralPath $target) -and ($source.TrimEnd('\') -ne $target.TrimEnd('\'))) {
    Write-Host "Replacing the existing $Version ..."
    Remove-Item -LiteralPath $target -Recurse -Force
}

New-Item -ItemType Directory -Path $Root -Force | Out-Null
if ($source.TrimEnd('\') -ne $target.TrimEnd('\')) {
    Write-Host "Installing to $target ..."
    Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
} else {
    Write-Host "Already at $target"
}

# ---- make it current -------------------------------------------------------
# A junction rather than a symlink: creating a symlink needs either elevation
# or Developer Mode, and a junction to a local directory needs neither. It is
# what `%LOCALAPPDATA%\WinMojo\current` has to be for an unprivileged install
# to work at all.
$currentLink = Join-Path $Root 'current'
if (Test-Path -LiteralPath $currentLink) {
    Remove-Item -LiteralPath $currentLink -Force -Recurse
}
New-Item -ItemType Junction -Path $currentLink -Target $target | Out-Null

# ---- and point it at itself ------------------------------------------------
# Through the copy's own relocator, so this script does not need to know what
# is in modular.cfg. Griddle does the same thing for itself at startup; doing
# it here as well means the very first command works even if that command is
# mojo.exe rather than the editor.
& cmd /c "call `"$target\paths.cmd`"" | Out-Null

if ($staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }

if (-not $NoShortcut) {
    # A Start-menu shortcut to the launcher rather than to the exe, so a
    # person who starts the IDE from the Start menu gets the same environment
    # as one who runs griddle.cmd from a terminal.
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $link = Join-Path $programs 'Griddle.lnk'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = Join-Path $currentLink 'bin\griddle.exe'
        $shortcut.WorkingDirectory = Join-Path $currentLink 'bin'
        $shortcut.Description = 'Griddle -- a Mojo IDE for Windows'
        $shortcut.Save()
        Write-Host "Start menu: $link"
    } catch {
        Write-Host "Could not create the Start menu shortcut: $_"
    }
}

Write-Host ""
Write-Host "Installed $Version"
Write-Host "  current : $currentLink -> $target"
Write-Host "  IDE     : $currentLink\bin\griddle.exe"
Write-Host "  compiler: $currentLink\mojo.cmd"
Write-Host ""
Write-Host "Griddle finds this installation through %LOCALAPPDATA%\WinMojo\current,"
Write-Host "so `.\install.ps1` on a newer package makes that one current without"
Write-Host "anything else changing. To remove one: .\install.ps1 -Uninstall -Version $Version"
