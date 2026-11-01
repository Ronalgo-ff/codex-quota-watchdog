# A reserve allowance belongs to one watcher run, never to global account order.
function Get-RunAccountPolicy {
    param($State,$Accounts)
    $policy=Get-StateFlag $State 'runAccountPolicy'
    if(-not $policy -or (Get-StateFlag $policy 'runId') -ne $Script:WatchRunId){
        $reserves=@($Accounts|Where-Object {Get-QuotaProperty $_ 'FiveHourLimitAbsent'})
        $selected=@($reserves|Where-Object {$_.Switchable -or $_.Active}|Sort-Object -Property @{Expression={$_.Weekly};Descending=$true},Id|Select-Object -First $Script:ReserveAccountCount|ForEach-Object {$_.Id})
        $policy=[pscustomobject]@{runId=$Script:WatchRunId;requestedCount=$Script:ReserveAccountCount;selectedIds=$selected;knownReserveIds=@($reserves|ForEach-Object {$_.Id});selectedAt=(Get-Date).ToString('o')}
        Set-StateFlag $State 'runAccountPolicy' $policy
        Save-State $State
        Write-Event $(if($Script:ReserveAccountCount -gt 0){"本次启用 $($selected.Count) 个备选账号，名单已固定；未选中的账号不会自动补入"}else{'本次未启用备选账号，仅使用普通账号'}) 'INFO'
    }
    $newIds=@($Accounts|Where-Object {(Get-QuotaProperty $_ 'FiveHourLimitAbsent') -and $_.Id -notin @($policy.knownReserveIds)}|ForEach-Object {$_.Id})
    if($newIds.Count -gt 0){
        $policy.knownReserveIds=@($policy.knownReserveIds)+$newIds
        Save-State $State
    }
    return $policy
}
function Get-RunAccounts {
    param($State,$Accounts)
    $policy=Get-RunAccountPolicy $State $Accounts
    return @($Accounts|Where-Object {Test-RunAccountEnabled $_ $policy})
}
