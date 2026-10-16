# Candidate selection only: do not connect to the real desktop or send messages.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\desktop.ps1')
$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
$modern='\\.\pipe\codex-app-tools-modern'
$legacy='\\.\pipe\codex-browser-use-legacy'
$paths=@($legacy,'\\.\pipe\codex-browser-use\browser-only',$modern,'\\.\pipe\codex-computer-use-other','\\.\pipe\unrelated',$modern)
$selected=@(Get-DesktopPipePaths -Paths $paths)
Check 'modern app-tools route is preferred and legacy route retained' ($selected.Count -eq 2 -and $selected[0] -eq $modern -and $selected[1] -eq $legacy)
Check 'browser-only and unrelated pipes are excluded' (@($selected|Where-Object {$_ -notin @($modern,$legacy)}).Count -eq 0)
Check 'old desktop remains discoverable without a modern route' (@(Get-DesktopPipePaths -Paths @($legacy)).Count -eq 1)
Check 'no candidates produces an empty list' (@(Get-DesktopPipePaths -Paths @()).Count -eq 0)
$env:CODEX_APP_TOOLS_PIPE_PATH=$null
function Get-DesktopPipePaths {return @($modern,$legacy)}
$script:CatalogCalls=@()
function Invoke-DesktopRpc($Path,$Method,$Params,$Timeout){
    $script:CatalogCalls+=$Path
    if($Path -eq $modern){return @{tools=@(@{namespace='browser';name='navigate'})}}
    return @{tools=@(@{namespace='codex_app';name='send_message_to_thread'})}
}
$chosen=Find-DesktopPipe
Check 'pipe name alone is insufficient; required app capability is verified' ($chosen -eq $legacy -and $script:CatalogCalls.Count -eq 2)
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
