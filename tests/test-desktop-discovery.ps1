$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('desktop-discovery-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
    $script:files=@()
    foreach($i in 1..7){
        $file=Join-Path $tmp ("rollout-thread-$i.jsonl")
        $source=if($i -eq 7){'subagent'}else{'vscode'}
        @{type='session_meta';payload=@{id="thread-$i";source=$source;originator='Codex Desktop'}}|ConvertTo-Json -Depth 4 -Compress|Set-Content $file -Encoding UTF8
        $script:files+=Get-Item $file
    }
    function Get-RecentSessions {$script:files}
    function Get-SessionFileStamp {param($File) (Get-Date).AddMinutes(-[int]($File.BaseName -replace 'rollout-thread-',''))}
    function Invoke-DesktopTool {param($Tool,$Arguments) [pscustomobject]@{pinnedThreads=@();threads=@([pscustomobject]@{id='thread-6';kind='codex';hostId='local';status='active';updatedAt=1});unavailableHosts=@()}}
    $script:reads=@()
    function Get-TurnView {param($ThreadId) $script:reads+=$ThreadId;[pscustomobject]@{Id=$ThreadId;Outcome=if($ThreadId -eq 'thread-1'){'running'}else{'finished'};Status=if($ThreadId -eq 'thread-1'){'active'}else{'idle'}}}
    $r=Get-DesktopSnapshot
    Check 'stale desktop index supplemented by real local desktop metadata' ($r.Recent[0].Id -eq 'thread-1')
    Check 'only most recent five are inspected' ($script:reads.Count -eq 5 -and $script:reads -notcontains 'thread-6')
    Check 'subagent metadata is excluded' ($script:reads -notcontains 'thread-7')
    Check 'running thread omitted from sidebar is still protected' (@($r.Active|Where-Object {$_.id -eq 'thread-1'}).Count -eq 1)
    Check 'older running sidebar thread is also protected' (@($r.Active|Where-Object {$_.id -eq 'thread-6'}).Count -eq 1)
    function Write-Event {param($Message,$Level)}
    $script:listCalls=0
    function Invoke-DesktopTool {param($Tool,$Arguments) $script:listCalls++;throw 'Desktop pipe response timeout; delivery may be uncertain'}
    function Get-TurnView {param($ThreadId) $script:reads+=$ThreadId;[pscustomobject]@{Id=$ThreadId;Outcome=if($ThreadId -eq 'thread-6'){'running'}else{'finished'};Status=if($ThreadId -eq 'thread-6'){'active'}else{'idle'}}}
    $script:reads=@();$r=Get-DesktopSnapshot
    Check 'list timeout falls back to genuine local recent five' ($r.Recent.Count -eq 5 -and $r.Recent[0].Id -eq 'thread-1' -and $script:DesktopHealth.mode -eq 'fallback')
    Check 'fallback verifies older running thread and protects it' ($script:reads -contains 'thread-6' -and @($r.Active|Where-Object {$_.id -eq 'thread-6'}).Count -eq 1)
    Get-DesktopSnapshot|Out-Null
    Check 'broken list is not requested on every poll' ($script:listCalls -eq 1)
    function Get-TurnView {param($ThreadId) throw 'Desktop pipe response timeout'}
    $threw=$false;try{Get-DesktopSnapshot|Out-Null}catch{$threw=$true}
    Check 'failed authoritative read never guesses idle from files' ($threw -and $script:DesktopHealth.mode -eq 'unavailable')
    $script:DesktopListingRetryAt=[datetime]::MinValue
    function Invoke-DesktopTool {param($Tool,$Arguments) [pscustomobject]@{pinnedThreads=@();threads=@();unavailableHosts=@()}}
    function Get-TurnView {param($ThreadId) [pscustomobject]@{Id=$ThreadId;Outcome='finished';Status='idle'}}
    $r=Get-DesktopSnapshot
    Check 'list recovery returns to normal routing' ($script:DesktopHealth.mode -eq 'ok' -and $r.Active.Count -eq 0)
    $script:files=@();$script:DesktopListingCache=@([pscustomobject]@{id='thread-6';kind='codex';hostId='local';status='idle';updatedAt=1});$script:DesktopListingRetryAt=(Get-Date).AddSeconds(60)
    $script:reads=@()
    function Get-TurnView {param($ThreadId) $script:reads+=$ThreadId;[pscustomobject]@{Id=$ThreadId;Outcome='running';Status='active';At=1}}
    $r=Get-DesktopSnapshot
    Check 'overnight expired local index still verifies cached identities' ($script:reads -contains 'thread-6' -and $r.Active.Count -eq 1 -and $r.Active[0].id -eq 'thread-6')
    Check 'expired cached turns never become resume candidates' ($r.Recent.Count -eq 0)
    $script:DesktopListingCache=@();$script:DesktopListingRetryAt=(Get-Date).AddSeconds(60)
    $threw=$false;try{Get-DesktopSnapshot|Out-Null}catch{$threw=$true}
    Check 'missing local metadata never permits an unverified switch' $threw
}finally{Remove-TestDirectory $tmp}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
