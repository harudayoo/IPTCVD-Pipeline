# Windows entry point for verify.sh -- runs it under Git Bash (never WSL's bash).
# Usage and options are identical to verify.sh:  .\verify.ps1 --help
# Execution policy blocking it?  powershell -ExecutionPolicy Bypass -File .\verify.ps1 ...
. (Join-Path $PSScriptRoot 'lib\win-bash.ps1')
Invoke-PipelineScript -Script (Join-Path $PSScriptRoot 'verify.sh') -Arguments $args
