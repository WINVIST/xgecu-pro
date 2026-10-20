param(
  [Parameter(Mandatory=$true)][string]$Helper,
  [Parameter(Mandatory=$true)][string]$NodeExecutable,
  [Parameter(Mandatory=$true)][string]$WorkerScript,
  [Parameter(Mandatory=$true)][string]$PlanFile
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'The helper-scoped firewall gate is CI-only and must not change a normal workstation network policy'}
$resolvedHelper=(Resolve-Path -LiteralPath $Helper).Path
$ruleName='XGecuPro-Offline-Gate-'+[guid]::NewGuid().ToString('N')
try{
  New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Outbound -Action Block -Program $resolvedHelper -Profile Any -Enabled True -PolicyStore PersistentStore|Out-Null
  $rule=Get-NetFirewallRule -Name $ruleName -PolicyStore ActiveStore
  if($rule.Enabled -ne 'True' -or $rule.Action -ne 'Block' -or $rule.Direction -ne 'Outbound'){throw 'The helper outbound block was not installed'}
  $filter=$rule|Get-NetFirewallApplicationFilter
  if($filter.Program -ine $resolvedHelper){throw 'The outbound rule is not scoped to the exact helper executable'}
  & $NodeExecutable $WorkerScript --isolated $PlanFile
  if($LASTEXITCODE -ne 0){throw "Offline helper checks failed: $LASTEXITCODE"}
}finally{
  Get-NetFirewallRule -Name $ruleName -PolicyStore PersistentStore -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction Stop
  if(Get-NetFirewallRule -Name $ruleName -PolicyStore PersistentStore -ErrorAction SilentlyContinue){throw 'The scoped offline firewall rule was not removed'}
}
