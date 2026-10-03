<#
.SYNOPSIS
  Runs the Prokop test suite inside WSL with maximum safe parallelism.
.DESCRIPTION
  Thin wrapper around tests/runner/run.sh; every argument is passed through.
.EXAMPLE
  .\tests\runner\run.ps1
  .\tests\runner\run.ps1 --serial
  .\tests\runner\run.ps1 --lanes static
  .\tests\runner\run.ps1 nft_apply 'autotune_*'
#>
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run.sh'
$linuxRunner = (& wsl.exe -e wslpath -a ($runner -replace '\\', '/')).Trim()
# PowerShell turns an unquoted a,b into an array; pass it on as one argument.
$runnerArgs = @(foreach ($arg in $args) { if ($arg -is [array]) { $arg -join ',' } else { $arg } })
& wsl.exe -e bash $linuxRunner @runnerArgs
exit $LASTEXITCODE
