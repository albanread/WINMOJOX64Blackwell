# W4.0: find the HTP's real model-size ceiling.
#
# THE RULE THIS SCRIPT EXISTS TO ENFORCE: after any HTP failure, re-run a
# known-good small model as a control. The DSP session layer wedges, and once
# wedged EVERY subsequent HTP run fails identically at session open - including
# models that ran fine minutes earlier. Without a control after each failure you
# will record the first failing size as "the ceiling" when it is nothing of the
# sort. That exact mistake was made and caught on 2026-08-19.
#
# A wedge is not recoverable by waiting or by killing processes. Reboot.
#
#   .\htp_ceiling_sweep.ps1 -Sizes @(512,1024,2048) -Layers 8

param(
    [int[]]$Sizes = @(512, 1024, 2048, 4096),
    [int]$Layers = 8,
    [string]$Work = "$env:TEMP\dragonmax-htp-sweep"
)

$ErrorActionPreference = "Continue"

$R = $env:QNN_SDK_ROOT
if (-not $R) { throw "QNN_SDK_ROOT is not set" }
$L = "$R\lib\aarch64-windows-msvc"
$NETRUN = "$R\bin\aarch64-windows-msvc\qnn-net-run.exe"
$DRAGON = Split-Path -Parent $PSCommandPath

$env:PATH = "$L;$R\bin\aarch64-windows-msvc;" + $env:PATH
$env:ADSP_LIBRARY_PATH = "$R\lib\hexagon-v81\unsigned"

New-Item -ItemType Directory -Force $Work | Out-Null

function Build-Model([int]$dim, [int]$layers) {
    $name = "mm_d${dim}_l${layers}"
    $gen = "$Work\gen"
    $bld = "$Work\build_$name"
    if (Test-Path "$bld\*\build\model-lib-windows.dll") {
        return (Get-ChildItem -Recurse -Filter model-lib-windows.dll $bld | Select-Object -First 1).FullName
    }
    python "$DRAGON\gen_matmul_model.py" --dim $dim --layers $layers --out $gen | Out-Null
    & "$DRAGON\build_model_lib.ps1" -Cpp "$gen\$name.cpp" -Bin "$gen\$name.bin" -Out $bld *>&1 | Out-Null
    $dll = Get-ChildItem -Recurse -Filter model-lib-windows.dll $bld -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { return $null }
    return $dll.FullName
}

function Stage-Input([int]$dim, [string]$dir) {
    New-Item -ItemType Directory -Force "$dir\in" | Out-Null
    $py = "import struct,pathlib;p=pathlib.Path(r'$dir');" +
          "p.joinpath('in','x.raw').write_bytes(b''.join(struct.pack('<f',(i%13-6)/32.0) for i in range($dim)));" +
          "p.joinpath('input_list.txt').write_text('input_0:=in/x.raw\n')"
    python -c $py
}

function Run-Backend([string]$backend, [string]$dll, [string]$dir, [string]$tag) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $o = & $NETRUN --backend "$L\$backend" --model $dll --input_list "$dir\input_list.txt" `
                   --output_dir "$dir\out_$tag" 2>&1
    $sw.Stop()
    $ok = ($o | Select-String "Finished Executing Graphs").Count -gt 0
    $err = ($o | Select-String "\[ ERROR \]" | Select-Object -First 1)
    return [pscustomobject]@{ Ok = $ok; Ms = $sw.Elapsed.TotalMilliseconds; Err = "$err" }
}

# The control model: small, known to run. Rebuilt once and reused.
Write-Host "Building control model (dim 512, 2 layers)..."
$controlDll = Build-Model 512 2
$controlDir = "$Work\control"
Stage-Input 512 $controlDir
if (-not $controlDll) { throw "control model failed to build" }

$c = Run-Backend "QnnHtp.dll" $controlDll $controlDir "ctl0"
if (-not $c.Ok) {
    Write-Host "`nHTP IS ALREADY WEDGED before the sweep started." -ForegroundColor Red
    Write-Host "  $($c.Err)"
    Write-Host "  Reboot before measuring anything. Results now would be meaningless."
    exit 2
}
Write-Host "control OK ($([int]$c.Ms) ms) - starting sweep`n"

$results = @()
foreach ($dim in $Sizes) {
    $mib = [math]::Round(($dim * $dim * 4.0 * $Layers) / 1MB, 1)
    Write-Host "== dim=$dim layers=$Layers  ($mib MiB of weights)"

    $dll = Build-Model $dim $Layers
    if (-not $dll) { Write-Host "  BUILD FAILED - stopping"; break }
    $dir = "$Work\run_d${dim}_l${Layers}"
    Stage-Input $dim $dir

    $cpu = Run-Backend "QnnCpu.dll" $dll $dir "cpu"
    $htp = Run-Backend "QnnHtp.dll" $dll $dir "htp"
    Write-Host ("  CPU {0,-5} {1,8:N0} ms" -f $(if ($cpu.Ok) {"ok"} else {"FAIL"}), $cpu.Ms)
    Write-Host ("  HTP {0,-5} {1,8:N0} ms" -f $(if ($htp.Ok) {"ok"} else {"FAIL"}), $htp.Ms)

    $verdict = "ok"
    if (-not $htp.Ok) {
        Write-Host "  HTP failed: $($htp.Err)"
        # The whole point. Did this size exceed a limit, or did the DSP wedge?
        Write-Host "  running control to tell a real ceiling from a wedge..."
        $ctl = Run-Backend "QnnHtp.dll" $controlDll $controlDir "ctl_after_$dim"
        if ($ctl.Ok) {
            $verdict = "CEILING - control still passes, so $mib MiB genuinely exceeded a limit"
            Write-Host "  -> $verdict" -ForegroundColor Yellow
        } else {
            $verdict = "WEDGED - control now fails too; this size proves nothing"
            Write-Host "  -> $verdict" -ForegroundColor Red
            Write-Host "  -> Reboot and resume the sweep from dim=$dim."
        }
    }
    $results += [pscustomobject]@{ Dim = $dim; MiB = $mib; Cpu = $cpu.Ok; Htp = $htp.Ok
                                   CpuMs = [int]$cpu.Ms; HtpMs = [int]$htp.Ms; Verdict = $verdict }
    if (-not $htp.Ok) { break }
}

Write-Host "`n===== summary ====="
$results | Format-Table -AutoSize
