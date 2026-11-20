# A reserve allowance belongs to one watcher run, never to global account order.
function Get-RunAccountPolicy {
    param($State,$Accounts)
    $policy=Get-StateFlag $State 'runAccountPolicy'
    if(-not $policy -or (Get-StateFlag $policy 'runId') -ne $Script:WatchRunId){
        $reserves=@($Accounts|Where-Object {Get-QuotaProperty $_ 'FiveHourLimitAbsent'})
        $eligible=@($reserves|Where-Object {$_.Switchable -or $_.Active})
        $selected=@(if($Script:ReserveAccountId){
            $eligible|Where-Object {$_.Id -eq $Script:ReserveAccountId}|ForEach-Object {$_.Id}
        }else{
            $eligible|Sort-Object -Property @{Expression={Get-AccountWeeklyResetOrder $_};Descending=$false},@{Expression={$_.Weekly};Descending=$true},Id|Select-Object -First $Script:ReserveAccountCount|ForEach-Object {$_.Id}
        })
        $policy=[pscustomobject]@{runId=$Script:WatchRunId;requestedCount=$Script:ReserveAccountCount;requestedId=$Script:ReserveAccountId;selectedIds=$selected;knownReserveIds=@($reserves|ForEach-Object {$_.Id});selectedAt=(Get-Date).ToString('o')}
        Set-StateFlag $State 'runAccountPolicy' $policy
        Save-State $State
        if($Script:ReserveAccountId -and $selected.Count -eq 0){
            Write-Event '指定的备选账号已不存在或无法切换；本次仅使用普通账号' 'WARN'
        }elseif($Script:ReserveAccountId -or $Script:ReserveAccountCount -gt 0){
            Write-Event "本次启用 $($selected.Count) 个备选账号，名单已固定；未选中的账号不会自动补入" 'INFO'
        }else{
            Write-Event '本次未启用备选账号，仅使用普通账号' 'INFO'
        }
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
    $active=@($Accounts|Where-Object {$_.Active})
    if($active.Count -eq 1){
        $selection=Get-StateFlag $State 'accountSelection'
        if(-not $selection -or (Get-StateFlag $selection 'accountId') -ne $active[0].Id){
            $intent=Get-StateFlag $State 'switchIntent'
            $mode=if($intent -and (Get-StateFlag $intent 'targetId') -eq $active[0].Id){'automatic'}else{'manual'}
            # Existing ordinary accounts need no manual override at startup.
            # A pre-existing reserve has no proven automatic owner after upgrade.
            if(-not $selection -and (Get-AccountPriority $active[0] $Script:Config.FallbackAccountIds) -eq 0){$mode='automatic'}
            Set-AccountSelection $State $active[0].Id $mode
            if($mode -eq 'manual'){Write-Event '当前账号由手动选择接管；额度可用时保留，不按自动备选名单或普通账号优先规则切走' 'INFO'}
        }
    }
    # The allowance restricts automatic choices, never a manually selected active
    # account. It does not add that account to the fixed automatic reserve list.
    return @($Accounts|Where-Object {(Test-RunAccountEnabled $_ $policy) -or ($_.Active -and (Test-ManualAccountSelection $State $_.Id))})
}
function Set-AccountSelection {
    param($State,[string]$AccountId,[ValidateSet('manual','automatic')][string]$Mode)
    Set-StateFlag $State 'accountSelection' ([pscustomobject]@{accountId=$AccountId;mode=$Mode;sinceEpoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()})
    Save-State $State
}
function Test-ManualAccountSelection {
    param($State,[string]$AccountId)
    $selection=Get-StateFlag $State 'accountSelection'
    return $selection -and (Get-StateFlag $selection 'accountId') -eq $AccountId -and (Get-StateFlag $selection 'mode') -eq 'manual'
}
