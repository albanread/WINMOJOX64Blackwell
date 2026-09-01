# make_setup.ps1 -- build a WinMojo setup program, start to finish.
#
# One command for the whole road: compile the IDE, stage the release tree,
# prove every example builds against the PACKAGED standard library, and wrap
# the result in an installer named for the day it was made.
#
#   .\make_setup.ps1                 fast build (about a minute of compression)
#   .\make_setup.ps1 -Lzma           small build, for something you publish
#   .\make_setup.ps1 -SkipBuild      package what is already in build\
#   .\make_setup.ps1 -Zip            also produce the plain archive
#
# NAMES. Setups are called winmojo-setup-YYYY_MM_DD_N.exe, where N counts
# from one each day: the second build of an afternoon is _2, and yesterday's
# _2 is still sitting there to compare against. A git hash names a commit
# but says nothing about which of the four you handed somebody, so the hash
# rides along inside -- in Apps & Features and in BUILD-REVISION.txt -- and
# the date is what the file is called.
#
# COMPRESSION. Fast by default, deliberately. Solid LZMA takes a quarter of
# an hour on this tree to save a hundred megabytes of download, which is a
# fine trade for a release and a terrible one for the eighth build of an
# afternoon. Both install in about twenty seconds; the difference is only
# what you wait for at this end.
#
# THE GATE. check-packaged.ps1 runs before anything is compressed, and a
# failure stops the build. It exists because a release once shipped in which
# not one example compiled: every sweep in this tree builds against the
# stdlib as SOURCE, a release ships it as a PACKAGE, and the two do not
# resolve the same names. Nothing gets wrapped here until it has been built
# the way the person who installs it will build it.
[CmdletBinding()]
param(
    # Solid LZMA rather than zlib: about half the size, about fifteen times
    # the wait.
    [switch]$Lzma,
    # Also write the plain .zip. It is a complete product on its own -- it
    # relocates itself wherever it is unpacked -- and costs a few minutes.
    [switch]$Zip,
    # Package build\griddle.exe as it stands, without compiling it again.
    [switch]$SkipBuild,
    # Package without proving the examples first. For when you are testing
    # the installer itself and know the tree is good.
    [switch]$SkipCheck,
    # Where the staged tree and the finished setup are written.
    [string]$OutDir = 'F:\winmojo-release'
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
if (-not $repo) { $repo = (Get-Location).Path }
$stage = Join-Path $OutDir 'stage'

function Say($text) { Write-Host "== $text" -ForegroundColor Cyan }
$started = Get-Date

# ---- 0. the tools we cannot do without ------------------------------------
$makensis = @(
    (Join-Path $repo 'build\nsis-3.11\makensis.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $makensis) {
    throw "makensis.exe not found. Unzip the portable NSIS into build\nsis-3.11, or install NSIS."
}

# A running editor holds its own executable open, and the compiler's failure
# to overwrite it reads as a build error rather than as what it is.
if (-not $SkipBuild) {
    $held = Get-Process griddle -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq (Join-Path $repo 'build\griddle.exe') }
    if ($held) {
        throw "Griddle is running from build\griddle.exe (pid $($held.Id -join ', ')). Close it, or pass -SkipBuild."
    }
}

# ---- 1. the IDE -----------------------------------------------------------
if ($SkipBuild) {
    Say 'skipping the IDE build'
    if (-not (Test-Path (Join-Path $repo 'build\griddle.exe'))) {
        throw "nothing to package: build\griddle.exe does not exist"
    }
} else {
    Say 'building the IDE'
    # From the repository root: build-ide.ps1 passes -I mojo/stdlib and -I .
    # relative, so where it runs from is part of what it means.
    Push-Location $repo
    try { & (Join-Path $repo 'tools\build-ide.ps1') }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "the IDE did not build" }
}

# ---- 2. the release tree --------------------------------------------------
Say "staging the release into $stage"
# A HASHTABLE splat, not an array one. Splatting an array into a PowerShell
# script passes its elements positionally: @('-Destination', $stage) binds
# the string "-Destination" to the first parameter and the path to the
# second, which here meant the packager was told the staging directory was
# the Bazel output base and went looking for windows_api.db inside it.
# Native executables take an array splat correctly, which is why makensis
# below still gets one; a .ps1 needs names.
$createArgs = @{ Destination = $stage }
if (-not $Zip) { $createArgs['NoArchive'] = $true }
& (Join-Path $repo 'release\windows\create-release.ps1') @createArgs
if ($LASTEXITCODE -ne 0) { throw "packaging failed" }

# ---- 3. the gate ----------------------------------------------------------
if ($SkipCheck) {
    Write-Warning 'skipping check-packaged: this setup has NOT been proven against the packaged stdlib'
} else {
    Say 'proving every example against the packaged stdlib'
    & (Join-Path $repo 'tools\check-packaged.ps1') -Root $stage
    if ($LASTEXITCODE -ne 0) {
        throw "examples do not build against the packaged stdlib; nothing was wrapped"
    }
}

# ---- 3a. nothing of this machine's goes in the box ------------------------
# The compiler caches into <root>\cache, so proving the examples fills it
# with 54 MB keyed to the machine that did the proving -- and it hides that
# under a dotted directory name, which is how it rode into three installers
# unnoticed. crashdb is the same kind of thing. Both are emptied rather than
# removed: the toolchain expects to find the directories, it just should not
# find anybody else's contents in them.
foreach ($scratch in @('cache', 'crashdb')) {
    $dir = Join-Path $stage $scratch
    if (Test-Path -LiteralPath $dir) {
        # -Force, because .mojo_cache is hidden and a listing without it
        # reports the directory as empty while it holds fifty megabytes.
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$staged = [math]::Round(
    ((Get-ChildItem -LiteralPath $stage -Recurse -File -Force |
        Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Say "tree is $staged MiB, scratch directories empty"

# ---- 4. today's number ----------------------------------------------------
# The N-th build of this day. Existing files are what remember it, so the
# count survives reboots, branches and this script being edited.
$today = (Get-Date).ToString('yyyy_MM_dd')
$taken = Get-ChildItem -LiteralPath $OutDir -Filter "winmojo-setup-${today}_*.exe" -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.BaseName -match "_(\d+)$") { [int]$matches[1] } else { 0 }
    }
$n = 1
if ($taken) { $n = ([int[]]$taken | Measure-Object -Maximum).Maximum + 1 }
$stamp = "${today}_$n"
$setup = Join-Path $OutDir "winmojo-setup-$stamp.exe"

# The commit rides inside, where it is useful, rather than in the filename,
# where it competes with the date for the same job.
$sha = ''
try { $sha = (& git -C $repo rev-parse --short HEAD 2>$null).Trim() } catch { }
$version = if ($sha) { "$stamp ($sha)" } else { $stamp }

# ---- 5. wrap it -----------------------------------------------------------
Say "wrapping $([System.IO.Path]::GetFileName($setup))  [$(if ($Lzma) { 'LZMA, slow' } else { 'zlib, fast' })]"
$nsiArgs = @('/V2', "/DRELEASE_DIR=$stage", "/DREVISION=$version", "/DOUTFILE=$setup")
if (-not $Lzma) { $nsiArgs += '/DQUICK' }
$nsiArgs += (Join-Path $repo 'release\windows\installer.nsi')
& $makensis @nsiArgs
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$setup.sha256",
    "$hash  $([System.IO.Path]::GetFileName($setup))`r`n",
    [System.Text.UTF8Encoding]::new($false))

$took = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
Write-Host "  setup     $setup" -ForegroundColor Green
Write-Host ('  size      {0:N1} MiB' -f ((Get-Item $setup).Length / 1MB))
Write-Host "  version   $version"
Write-Host "  sha256    $hash"
Write-Host "  took      $([int]($took / 60))m $($took % 60)s"
Write-Host ''
Write-Host "  prove it:  .\tools\check-install.ps1 -Setup `"$setup`""
