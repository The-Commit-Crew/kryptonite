param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoBin,
    [ValidateSet('tb_shared_poly_multiplier', 'tb_encrypt', 'tb_board1_send',
                 'tb_board1_top', 'tb_board1_top_live', 'tb_decryption_ntt')]
    [string[]]$Tests = @('tb_shared_poly_multiplier', 'tb_encrypt', 'tb_board1_send', 'tb_decryption_ntt',
                         'tb_board1_top', 'tb_board1_top_live')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$rtl = Join-Path $repo 'kryptonite/kryptonite.srcs/sources_1/new'
$mem = Join-Path $repo 'kryptonite/kryptonite.srcs/sources_1/imports/mem_files'
$run = Join-Path $repo '.crypto.sim'
New-Item -ItemType Directory -Path $run -Force | Out-Null

# Stage only public encryption inputs. Local Board 2 secret files are not copied.
foreach ($relative in @('crypto/keys/board1', 'crypto/test_vectors/noise',
                         'crypto/test_vectors/ciphertext')) {
    $destination = Join-Path $run $relative
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $repo $relative) -File |
        Copy-Item -Destination $destination
}
Get-ChildItem -LiteralPath $mem -Filter '*.mem' | Copy-Item -Destination $run

function Invoke-Xilinx([string]$Tool, [string[]]$ToolArgs) {
    & (Join-Path $VivadoBin "$Tool.bat") @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed with exit code $LASTEXITCODE" }
}

Push-Location $run
try {
    $sources = @(Get-ChildItem -LiteralPath $rtl -Filter '*.v' | ForEach-Object FullName)
    $sources += @(Get-ChildItem -LiteralPath (Join-Path $repo 'anannya_ui') -Filter '*.v' |
                  Where-Object Name -NotLike 'tb_*' | ForEach-Object FullName)
    $sources += Join-Path $repo 'kryptonite/kryptonite.srcs/sim_1/new/tb_decryption_ntt.v'
    $benches = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.sv' | ForEach-Object FullName)
    Invoke-Xilinx 'xvhdl' @('--work', 'xil_defaultlib', (Join-Path $rtl 'Ps2Interface.vhd'),
                           (Join-Path $rtl 'Mouse_Control.vhd'))
    Invoke-Xilinx 'xvlog' (@('--work', 'xil_defaultlib') + $sources)
    Invoke-Xilinx 'xvlog' (@('--work', 'xil_defaultlib', '--sv') + $benches)
    foreach ($test in $Tests) {
        if ($test -in @('tb_board1_top', 'tb_board1_top_live')) {
            $pattern = if ($test -eq 'tb_board1_top_live') { 'top_0_*.mem' } else { 'top_1_*.mem' }
            # These are generated captures inside the fixed workspace run directory.
            Get-ChildItem -LiteralPath $run -Filter $pattern -File | Remove-Item
        }
        Invoke-Xilinx 'xelab' @('-mt', '2', '-debug', 'typical', '-s', $test, "xil_defaultlib.$test")
        # Captures also allow Python to check live-noise RTL ciphertext below.
        Invoke-Xilinx 'xsim' @($test, '-runall', '-onfinish', 'quit', '-log', "$test.log",
                              '-testplusarg', 'capture_live', '-testplusarg', 'capture_top')
        $log = Get-Content -LiteralPath "$test.log" -Raw
        if ($log -match '(?im)^\s*(Fatal:|Error:|FAIL\b|TIMEOUT:)' -or $log -notmatch 'PASS:') {
            throw "$test did not pass; see $run/$test.log"
        }
    }
    if ($Tests -contains 'tb_encrypt' -or $Tests -contains 'tb_board1_top_live') {
        & python -B (Join-Path $PSScriptRoot 'check_crypto_captures.py') --run-dir $run --tests $Tests
        if ($LASTEXITCODE -ne 0) { throw 'Python ciphertext verification failed' }
    }
    Write-Host "PASS: requested crypto regressions completed. Logs: $run"
} finally {
    Pop-Location
}
