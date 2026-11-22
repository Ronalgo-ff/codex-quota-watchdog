# Catalog succeeds but read transport times out. Next operation chooses another pipe.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\desktop.ps1')
$Script:Config=@{DesktopCallerThreadId='fixture-caller'}
$savedPipe=$env:CODEX_APP_TOOLS_PIPE_PATH;$env:CODEX_APP_TOOLS_PIPE_PATH='stale'
$script:DesktopPipe='stale';$script:readCalls=@();$script:sendCalls=0;$pass=0;$fail=0
$script:onlyListingTimesOut=$true
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
function Get-DesktopPipePaths{return @('stale','healthy')}
function Invoke-DesktopRpc($Path,$Method,$Params,$Timeout){
    if($Method -eq 'tools/list'){return @{tools=@(@{namespace='codex_app';name='send_message_to_thread'})}}
    if($Params.tool -eq 'send_message_to_thread'){$script:sendCalls++;throw 'Desktop pipe response timeout; delivery may be uncertain'}
    $script:readCalls+=$Path
    if($Path -eq 'stale' -and (-not $script:onlyListingTimesOut -or $Params.tool -eq 'list_threads')){throw 'Desktop pipe response timeout; delivery may be uncertain'}
    return @{success=$true;contentItems=@(@{type='inputText';text='{"ok":true}'})}
}
$threw=$false;try{Invoke-DesktopTool 'list_threads'|Out-Null}catch{$threw=$true}
Check 'list response timeout is reported without quarantining its transport' ($threw -and $script:readCalls.Count -eq 1 -and $script:DesktopPipe -eq 'stale' -and $script:DesktopPipeCooldown.Count -eq 0)
$reply=Invoke-DesktopTool 'read_thread' @{threadId='fixture'}
Check 'individual verification can proceed immediately on the same pipe' ($reply.ok -and $script:readCalls[-1] -eq 'stale')
$script:onlyListingTimesOut=$false;$script:readCalls=@()
$threw=$false;try{Invoke-DesktopTool 'read_thread' @{threadId='fixture'}|Out-Null}catch{$threw=$true}
Check 'failed read marks stale route without replaying within same call' ($threw -and $script:readCalls.Count -eq 1 -and $null -eq $script:DesktopPipe)
$reply=Invoke-DesktopTool 'read_thread' @{threadId='fixture'}
Check 'next read uses another responsive desktop pipe' ($reply.ok -and $script:readCalls[-1] -eq 'healthy' -and $script:DesktopPipe -eq 'healthy')
Check 'failed route is temporarily quarantined' ($script:DesktopPipeCooldown['stale'] -gt (Get-Date))
$threw=$false;try{Invoke-DesktopTool 'send_message_to_thread' @{threadId='fixture';prompt='fixture'}|Out-Null}catch{$threw=$true}
Check 'uncertain sends remain single-attempt and propagate failure' ($threw -and $script:sendCalls -eq 1)
$env:CODEX_APP_TOOLS_PIPE_PATH=$savedPipe
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
