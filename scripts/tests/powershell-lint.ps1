# Parse every tracked PowerShell script; then PSScriptAnalyzer at Error and
# Warning level. Called by scripts/tests/powershell-lint.sh.
$ErrorActionPreference = 'Stop'
$AnalyzerVersion = '1.25.0'

$files = @(git ls-files -co --exclude-standard '*.ps1' | Where-Object { $_ -notlike 'private/*' })
if ($files.Count -eq 0) { Write-Host 'no PowerShell scripts'; exit 0 }

$failed = $false
foreach ($f in $files) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$errors)
    if ($errors) {
        $failed = $true
        foreach ($e in $errors) { Write-Host "${f}:$($e.Extent.StartLineNumber): parse error: $($e.Message)" }
    }
}
if ($failed) { exit 1 }
Write-Host "$($files.Count) script(s) parse"

if (-not (Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq $AnalyzerVersion)) {
    Install-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion

# Excluded on purpose:
#   PSAvoidUsingWriteHost         the scripts are operator tools whose output is the report
#   PSUseShouldProcessForStateChangingFunctions, PSUseSingularNouns
#                                 naming advice for module authors, not for these helpers
#   PSAvoidUsingPositionalParameters, PSReviewUnusedParameter
#                                 noise for small private functions that take ($a, $b)
$exclude = 'PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns',
    'PSAvoidUsingPositionalParameters', 'PSReviewUnusedParameter'
$findings = foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f -Severity Error, Warning -ExcludeRule $exclude }
if ($findings) {
    $findings | ForEach-Object { Write-Host "$($_.ScriptName):$($_.Line): $($_.Severity) $($_.RuleName): $($_.Message)" }
    exit 1
}
Write-Host 'PSScriptAnalyzer: no findings'
