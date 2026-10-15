# Pure UI helpers; reads snapshots only, no account mutations.
function Read-DashboardJson($Path){
    $reader=$null
    try{
        if(Test-Path -LiteralPath $Path){
            # The writer atomically replaces snapshots. Readers must allow deletion.
            $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $reader=New-Object IO.StreamReader([IO.File]::Open($Path,'Open','Read',$share),[Text.Encoding]::UTF8)
            return ($reader.ReadToEnd()|ConvertFrom-Json)
        }
    }catch{}finally{if($reader){$reader.Dispose()}}
    return $null
}
function Get-DashboardRun($Root){
    $run=Read-DashboardJson (Join-Path $Root 'state\current-run.json')
    if(-not $run){return $null}
    try{$p=Get-Process -Id $run.pid -ErrorAction Stop;if([Math]::Abs(($p.StartTime-[datetime]::Parse($run.processStartedAt)).TotalSeconds)-lt 2){return $run}}catch{}
    return $null
}
function Send-DashboardCommand($Root,$Action,[switch]$Watcher){
    $path=Join-Path $Root $(if($Watcher){'state\tray-control.json'}else{'state\tray-host-command.json'})
    $id=[guid]::NewGuid().ToString('N');$tmp=$path+'.tmp'
    $null=New-Item -ItemType Directory (Split-Path $path -Parent) -Force
    [IO.File]::WriteAllText($tmp,(@{id=$id;action=$Action;at=(Get-Date).ToString('o')}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $id
}
function Format-DashboardElapsed($Run,$Now=(Get-Date)){
    if(-not $Run){return '尚未启动'}
    $elapsed=$Now-[datetime]::Parse($Run.startedAt)
    if($elapsed.TotalHours -ge 1){return ('{0}小时{1}分{2}秒' -f [int][math]::Floor($elapsed.TotalHours),$elapsed.Minutes,$elapsed.Seconds)}
    return ('{0}分{1}秒' -f [int][math]::Max(0,[math]::Floor($elapsed.TotalMinutes)),$elapsed.Seconds)
}
function Get-DashboardEvents($Root,$Run){
    if(-not $Run){return @()}
    $path=[IO.Path]::GetFullPath([string]$Run.eventFile)
    $logs=[IO.Path]::GetFullPath((Join-Path $Root 'logs'))+'\'
    if(-not $path.StartsWith($logs,[StringComparison]::OrdinalIgnoreCase)){return @()}
    if(Test-Path $path){return @(Get-Content -LiteralPath $path -Tail 150 -Encoding UTF8|Where-Object {$_.Trim()})}
    return @()
}
function Format-DashboardPercent($Number,$ErrorText){if($ErrorText -or $null -eq $Number){return '--'};return ('{0:0.#}%' -f [double]$Number)}
