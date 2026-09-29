# Windows entry point for configure.sh -- runs it under Git Bash (never WSL's bash).
# Usage and options are identical to configure.sh:  .\configure.ps1 --help
# Execution policy blocking it?  powershell -ExecutionPolicy Bypass -File .\configure.ps1 ...
. (Join-Path $PSScriptRoot 'lib\win-bash.ps1')
Invoke-PipelineScript -Script (Join-Path $PSScriptRoot 'configure.sh') -Arguments $args
