#requires -Version 7.4
param(
    [string]$Application = $env:XGECU_E2E_APP,
    [switch]$RequireMedium,
    [string]$ExpectedUserSid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This launcher requires Windows.' }
if (-not $Application -or -not (Test-Path -LiteralPath $Application -PathType Leaf)) {
    throw 'XGECU_E2E_APP must identify the installed application executable.'
}
$Application = (Resolve-Path -LiteralPath $Application).ProviderPath
$appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not ('Xgecu.Qa.MediumLaunch' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'windows-medium-launch.cs') }
$integrityRid = [Xgecu.Qa.MediumLaunch]::CurrentIntegrity()
$tokenElevation = [Xgecu.Qa.MediumLaunch]::CurrentElevated()
$userSid = [Xgecu.Qa.MediumLaunch]::CurrentUserSid()
if ($ExpectedUserSid -and $ExpectedUserSid -ne $userSid) { throw 'The QA process user differs from the launching user.' }
if ($RequireMedium -and ($integrityRid -ne 8192 -or $tokenElevation)) {
    throw "The delegated QA process must be Medium/non-elevated; actual RID=$integrityRid, TokenElevation=$tokenElevation."
}
if ($integrityRid -lt 8192 -or $userSid -eq 'S-1-5-18') { throw 'QA requires an interactive user token at Medium Integrity or above.' }
if ($integrityRid -ne 8192 -or $tokenElevation) {
    # High-IL WebView2 ignores user-scoped WEBVIEW2_* overrides. Re-run the
    # entire QA branch at Medium IL; app, npm, and drivers inherit that token.
    # https://learn.microsoft.com/microsoft-edge/webview2/concepts/security
    $bootstrapDirectory = Join-Path $appRoot ('test-results\windows-native-bootstrap-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $bootstrapDirectory -Force | Out-Null
    $bootstrapFile = Join-Path $bootstrapDirectory 'token-launch.json'
    $bootstrap = [ordered]@{
        callerIntegrityRid = $integrityRid; callerTokenElevation = $tokenElevation; userSid = $userSid
        expectedChildIntegrityRid = 8192; expectedChildTokenElevation = $false
        application = $Application; started = [DateTime]::UtcNow.ToString('o'); childExitCode = $null
    }
    $bootstrapEncoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($bootstrapFile, ($bootstrap | ConvertTo-Json), $bootstrapEncoding)
    try {
        $powershellExecutable = [System.Environment]::ProcessPath
        $childArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
            '-Application', $Application, '-RequireMedium', '-ExpectedUserSid', $userSid)
        Write-Output "[windows-native] Delegating same-user QA: RID=$integrityRid, TokenElevation=$tokenElevation -> Medium/non-elevated"
        $bootstrap.childExitCode = [Xgecu.Qa.MediumLaunch]::Run($powershellExecutable, $childArguments, $appRoot,
            (Join-Path $bootstrapDirectory 'qa.stdout.log'), (Join-Path $bootstrapDirectory 'qa.stderr.log'))
        if ($bootstrap.childExitCode -ne 0) { throw "The Medium Integrity QA branch failed (exit $($bootstrap.childExitCode))." }
    } finally {
        $bootstrap.finished = [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllText($bootstrapFile, ($bootstrap | ConvertTo-Json), $bootstrapEncoding)
        Write-Output "Same-user token delegation evidence retained at $bootstrapDirectory"
    }
    return
}
Write-Output "[windows-native] Actual QA token: integrity RID=$integrityRid, TokenElevation=$tokenElevation; same user confirmed"
$npm = (Get-Command npm.cmd -ErrorAction Stop).Source
$runDirectory = Join-Path $appRoot ('test-results\windows-native-' + [guid]::NewGuid().ToString('N'))
$webviewProfile = Join-Path $runDirectory 'webview2-profile'
New-Item -ItemType Directory -Path $webviewProfile -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$progressFile = Join-Path $runDirectory 'progress.jsonl'
$metadataFile = Join-Path $runDirectory 'environment.json'

function Write-NativeProgress([string]$Phase, [hashtable]$Details = @{}) {
    $entry = @{ time = [DateTime]::UtcNow.ToString('o'); phase = $Phase }
    foreach ($key in $Details.Keys) { $entry[$key] = $Details[$key] }
    [System.IO.File]::AppendAllText($progressFile, ($entry | ConvertTo-Json -Compress -Depth 5) + "`n", $utf8)
    Write-Output "[windows-native] $($entry.time) $Phase"
}

function Assert-OwnedLoopbackListener([int]$Port, [int]$AppProcessId) {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    if ($listeners.Count -eq 0) { throw 'The CDP listener has not appeared.' }
    foreach ($listener in $listeners) {
        if ($listener.LocalAddress -notin @('127.0.0.1', '::1')) {
            throw 'The CDP endpoint is not bound exclusively to loopback.'
        }
        $owner = [int]$listener.OwningProcess
        $ancestor = $owner
        $owned = $false
        for ($depth = 0; $depth -lt 16 -and $ancestor -gt 0; $depth++) {
            if ($ancestor -eq $AppProcessId) { $owned = $true; break }
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" -ErrorAction Stop
            if ($null -eq $process -or $process.ParentProcessId -eq $ancestor) { break }
            $ancestor = [int]$process.ParentProcessId
        }
        if (-not $owned) { throw 'The CDP listener is not owned by this application process tree.' }
    }
}

# Reserve a free loopback port, then verify the actual listener's ownership
# after launch so another process cannot accidentally become the test target.
$reservation = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$reservation.Start()
$port = ([System.Net.IPEndPoint]$reservation.LocalEndpoint).Port
$reservation.Stop()
$attachAddress = "127.0.0.1:$port"
$arguments = "--remote-debugging-port=$port --remote-debugging-address=127.0.0.1"
$childEnvironment = @{
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $arguments
    WEBVIEW2_USER_DATA_FOLDER = $webviewProfile
}
$metadata = [ordered]@{
    application = $Application; attachAddress = $attachAddress; userDataFolder = $webviewProfile
    browserArguments = $arguments; appProcessId = $null; ready = $false; testExitCode = $null
    integrityRid = $integrityRid; tokenElevation = $tokenElevation; userSid = $userSid
    hardwareTested = $false; started = [DateTime]::UtcNow.ToString('o')
}
$app = $null
$previousAttach = $env:XGECU_E2E_ATTACH_ADDRESS
try {
    Write-NativeProgress 'application:start' @{ application = $Application; attachAddress = $attachAddress }
    # This is the interactive GUI being tested. Keep it mapped for native
    # keyboard/focus checks; the WebDriver background helper hides its window.
    $app = Start-Process -FilePath $Application -WorkingDirectory (Split-Path -Parent $Application) `
        -Environment $childEnvironment -WindowStyle Normal -PassThru `
        -RedirectStandardOutput (Join-Path $runDirectory 'application.stdout.log') `
        -RedirectStandardError (Join-Path $runDirectory 'application.stderr.log')
    $metadata.appProcessId = $app.Id
    [System.IO.File]::WriteAllText($metadataFile, ($metadata | ConvertTo-Json -Depth 5), $utf8)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = 'No CDP response.'
    while ($clock.Elapsed.TotalSeconds -lt 20) {
        $app.Refresh()
        if ($app.HasExited) { throw "The installed application exited before CDP readiness (exit $($app.ExitCode))." }
        try {
            $version = Invoke-RestMethod -Uri "http://$attachAddress/json/version" -TimeoutSec 1 -NoProxy
            $socket = [uri]$version.webSocketDebuggerUrl
            if ($socket.Scheme -ne 'ws' -or $socket.Host -notin @('127.0.0.1', 'localhost', '[::1]', '::1') -or $socket.Port -ne $port) {
                throw 'The CDP response did not identify the expected loopback WebSocket.'
            }
            Assert-OwnedLoopbackListener -Port $port -AppProcessId $app.Id
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'devtools-version.json'), ($version | ConvertTo-Json -Depth 5), $utf8)
            $metadata.ready = $true
            Write-NativeProgress 'cdp:ready' @{ processId = $app.Id; browser = $version.Browser; milliseconds = $clock.ElapsedMilliseconds }
            break
        } catch { $lastError = $_.Exception.Message }
        Start-Sleep -Milliseconds 200
    }
    if (-not $metadata.ready) { throw "CDP did not become ready within 20 seconds: $lastError" }
    $env:XGECU_E2E_ATTACH_ADDRESS = $attachAddress
    Push-Location $appRoot
    try {
        Write-NativeProgress 'webdriver:start'
        & $npm run test:e2e 2>&1 | Tee-Object -FilePath (Join-Path $runDirectory 'webdriver.log')
        $metadata.testExitCode = $LASTEXITCODE
        Write-NativeProgress 'webdriver:end' @{ exitCode = $LASTEXITCODE }
        if ($metadata.testExitCode -ne 0) { throw "Native WebDriver checks failed (exit $($metadata.testExitCode))." }
    } finally { Pop-Location }
} catch {
    Write-NativeProgress 'failure' @{ message = $_.Exception.Message }
    throw
} finally {
    $env:XGECU_E2E_ATTACH_ADDRESS = $previousAttach
    $cleanupFailure = $null
    try {
        if ($null -ne $app) {
            $app.Refresh()
            if (-not $app.HasExited) {
                Write-NativeProgress 'application:close' @{ processId = $app.Id }
                [void]$app.CloseMainWindow()
                if (-not $app.WaitForExit(5000)) {
                    Write-NativeProgress 'application:terminate-owned-process' @{ processId = $app.Id }
                    $app.Kill()
                    if (-not $app.WaitForExit(5000)) { throw 'The owned application did not terminate.' }
                }
            }
        }
    } catch {
        $cleanupFailure = $_.Exception
        Write-NativeProgress 'application:cleanup-failure' @{ message = $_.Exception.Message }
    } finally { if ($null -ne $app) { $app.Dispose() } }
    $metadata.finished = [DateTime]::UtcNow.ToString('o')
    [System.IO.File]::WriteAllText($metadataFile, ($metadata | ConvertTo-Json -Depth 5), $utf8)
    Write-Output "Windows native evidence and private WebView2 profile retained at $runDirectory"
    if ($null -ne $cleanupFailure) { throw $cleanupFailure }
}
