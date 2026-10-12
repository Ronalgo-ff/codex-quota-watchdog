$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\scheduler.ps1')
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-schedule-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $tmp
$script:ScheduleRoot=$tmp;$pass=0;$fail=0;$script:registered=$null;$script:enabled=$null;$script:taskExists=$false
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function New-ScheduledTaskAction($Execute,$Argument,$WorkingDirectory){return @{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
function Get-ScheduledTask($TaskName){if($script:taskExists){return @{name=$TaskName}}}
function New-ScheduledTaskTrigger($Daily,$At){return @{at=$At}}
function New-ScheduledTaskPrincipal($UserId,$LogonType,$RunLevel){return @{}}
function New-ScheduledTaskSettingsSet($AllowStartIfOnBatteries,$DontStopIfGoingOnBatteries,$StartWhenAvailable,$WakeToRun,$MultipleInstances,$ExecutionTimeLimit){return @{}}
function Register-ScheduledTask($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,$Force){$script:registered=@{action=$Action;triggers=$Trigger};$script:taskExists=$true}
function Set-ScheduledTask($TaskName,$Action,$Trigger){$script:registered=@{action=$Action;triggers=$Trigger}}
function Enable-ScheduledTask($TaskName){$script:enabled=$true}
function Disable-ScheduledTask($TaskName){$script:enabled=$false}
try{
 Check 'times sort and deduplicate' ((@(Normalize-ScheduleTimes @('10:35','07:50','10:35')) -join ',') -eq '07:50,10:35')
 $bad=$false;try{Normalize-ScheduleTimes @('99:99')|Out-Null}catch{$bad=$true};Check 'invalid time rejected' $bad
 Write-ScheduleJson (Join-Path $tmp 'rules.json') @{ResumeMode='desktop';DesktopReadyDelaySec=10}
 # Switch parameter stubs keep task registration isolated.
 function New-ScheduledTaskTrigger {param([switch]$Daily,$At) return @{at=$At}}
 function New-ScheduledTaskSettingsSet {param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,[switch]$WakeToRun,$MultipleInstances,$ExecutionTimeLimit) return @{}}
 function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,[switch]$Force) $script:registered=@{action=$Action;triggers=$Trigger};$script:taskExists=$true}
 Set-ScheduleConfig 18080 @('10:35','07:50')
 $cfg=Get-ScheduleConfig
 Check 'multiple schedule times persist and enable task' ($cfg.enabled -and @($cfg.times).Count -eq 2 -and $script:enabled)
 Check 'task action uses project scheduler and working directory' ($script:registered.action.Arguments.Contains((Join-Path $tmp 'scheduler.ps1')) -and $script:registered.action.WorkingDirectory -eq $tmp)
 Set-ScheduleConfig 18081 @('10:35')
 $rules=Read-ScheduleJson (Join-Path $tmp 'rules.json')
 Check 'shared port updates endpoint while preserving watcher rules' ($rules.CswEndpoint -eq 'http://127.0.0.1:18081/__codex_switch__/api/invoke' -and $rules.DesktopReadyDelaySec -eq 10)
 Set-ScheduleConfig 18081 @()
 Check 'empty list disables task without deleting settings or accounts' (-not (Get-ScheduleConfig).enabled -and -not $script:enabled)
 Set-ScheduleConfig 18081 @('10:35') $false
 Check 'disabled schedule retains time' (-not (Get-ScheduleConfig).enabled -and (Get-ScheduleConfig).times[0] -eq '10:35')
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
