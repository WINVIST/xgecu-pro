#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This check requires Windows.' }
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $PSScriptRoot 'windows-medium-launch.cs'
if (-not ('Xgecu.Qa.MediumLaunch' -as [type])) { Add-Type -Path $helper }
$evidence = Join-Path $appRoot ('test-results\windows-token-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$encoding = [Text.UTF8Encoding]::new($false)
$resultFile = Join-Path $evidence 'child-token.json'
$childFile = Join-Path $evidence 'probe.ps1'
$childSource = @'
param([string]$HelperSource, [string]$ExpectedUserSid, [string]$ResultPath)
$ErrorActionPreference = 'Stop'
Add-Type -Path $HelperSource
$measured = [ordered]@{
    integrityRid = [Xgecu.Qa.MediumLaunch]::CurrentIntegrity()
    tokenElevation = [Xgecu.Qa.MediumLaunch]::CurrentElevated()
    userSid = [Xgecu.Qa.MediumLaunch]::CurrentUserSid()
    desktop = [Xgecu.Qa.MediumLaunch]::CurrentDesktop()
}
[IO.File]::WriteAllText($ResultPath, ($measured | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
if ($measured.integrityRid -ne 8192 -or $measured.tokenElevation -or $measured.userSid -ne $ExpectedUserSid) {
    throw 'The native QA child must be Medium/non-elevated and retain the same user.'
}
Write-Output 'Native QA child: measured Medium Integrity and non-elevated token.'
'@
[IO.File]::WriteAllText($childFile, $childSource, $encoding)
$caller = [ordered]@{
    integrityRid = [Xgecu.Qa.MediumLaunch]::CurrentIntegrity()
    tokenElevation = [Xgecu.Qa.MediumLaunch]::CurrentElevated()
    userSid = [Xgecu.Qa.MediumLaunch]::CurrentUserSid()
    desktop = [Xgecu.Qa.MediumLaunch]::CurrentDesktop()
}
[IO.File]::WriteAllText((Join-Path $evidence 'caller-token.json'), ($caller | ConvertTo-Json), $encoding)
$arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childFile,
    '-HelperSource', $helper, '-ExpectedUserSid', $caller.userSid, '-ResultPath', $resultFile)
$exitCode = [Xgecu.Qa.MediumLaunch]::Run([Environment]::ProcessPath, $arguments, $appRoot,
    (Join-Path $evidence 'stdout.log'), (Join-Path $evidence 'stderr.log'))
if ($exitCode -ne 0) {
    $hexCode = '{0:X8}' -f ([uint32]([long]$exitCode -band 4294967295L))
    [IO.File]::WriteAllText((Join-Path $evidence 'child-exit.json'),
        (@{ exitCode = $exitCode; hexCode = $hexCode } | ConvertTo-Json), $encoding)
    # Distinguish a PowerShell initialization failure from a failure of every
    # restricted process, using the same launcher and an OS-provided executable.
    try {
        $cmdExit = [Xgecu.Qa.MediumLaunch]::Run($env:ComSpec,
            @('/d', '/c', 'echo XGECU_NATIVE_PROBE'), $appRoot,
            (Join-Path $evidence 'cmd.stdout.log'), (Join-Path $evidence 'cmd.stderr.log'))
        [IO.File]::WriteAllText((Join-Path $evidence 'cmd-exit.json'),
            (@{ exitCode = $cmdExit } | ConvertTo-Json), $encoding)
        Write-Output "Restricted OS command diagnostic: exit $cmdExit"
    } catch {
        [IO.File]::WriteAllText((Join-Path $evidence 'cmd-launch-error.txt'), $_.ToString(), $encoding)
    }
    throw "Native QA token probe failed: exit $exitCode (0x$hexCode). Evidence: $evidence"
}
$measured = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
if ($measured.integrityRid -ne 8192 -or $measured.tokenElevation -or $measured.userSid -ne $caller.userSid) {
    throw 'Native QA token evidence does not match the required privilege level.'
}
Write-Output "Native QA token probe passed; evidence retained at $evidence"
