param([string]$DriverDirectory)
$ErrorActionPreference='Stop'
# The Edge browser and the Evergreen WebView2 Runtime update independently.
# Match the runtime used by the installed app, not msedge.exe.
$runtimeVersions=@()
foreach($runtimeRoot in @("${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application","$env:LOCALAPPDATA\Microsoft\EdgeWebView\Application")){
  if(Test-Path -LiteralPath $runtimeRoot){
    $runtimeVersions+=Get-ChildItem -LiteralPath $runtimeRoot -Directory|Where-Object {$_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'msedgewebview2.exe'))}|ForEach-Object {[version]$_.Name}
  }
}
if(-not $runtimeVersions){throw 'WebView2 Runtime was not installed by the application installer'}
$version=($runtimeVersions|Sort-Object -Descending|Select-Object -First 1).ToString()
if(-not $DriverDirectory){$DriverDirectory=Join-Path $env:RUNNER_TEMP 'edge-driver'}
$driverDirectory=$DriverDirectory
New-Item -ItemType Directory -Force -Path $driverDirectory|Out-Null
$zip=Join-Path $driverDirectory 'driver.zip'
try{
  Invoke-WebRequest -Uri "https://msedgedriver.microsoft.com/$version/edgedriver_win64.zip" -OutFile $zip
}catch{
  $major=$version.Split('.')[0]
  $available=(Invoke-RestMethod -Uri "https://msedgedriver.microsoft.com/LATEST_RELEASE_${major}_WINDOWS").Trim()
  if(($available.Split('.')[0..2]-join '.') -ne ($version.Split('.')[0..2]-join '.')){throw "No WebDriver matching WebView2 $version was found"}
  Invoke-WebRequest -Uri "https://msedgedriver.microsoft.com/$available/edgedriver_win64.zip" -OutFile $zip
}
Expand-Archive -LiteralPath $zip -DestinationPath $driverDirectory -Force
$driverVersion=& (Join-Path $driverDirectory 'msedgedriver.exe') --version
if($driverVersion -notmatch '(\d+\.\d+\.\d+)\.') {throw 'Could not inspect the downloaded WebDriver version'}
if($Matches[1] -ne ($version.Split('.')[0..2]-join '.')){throw "WebDriver does not match WebView2 $version"}
if($env:GITHUB_PATH){$driverDirectory|Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append}
Write-Output "WebView2 $version; $driverVersion"
