# Shared quota interpretation for the watcher, dashboard and batch worker.
function Get-QuotaProperty($Object,[string]$Name){
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    if($Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $null
}
function ConvertFrom-AccountUsage($Usage){
    $primary=Get-QuotaProperty $Usage 'primary';$secondary=Get-QuotaProperty $Usage 'secondary'
    $fiveWindow=$null;$weekWindow=$null;$absent=$false
    $windows=@(@($primary,$secondary)|Where-Object {$null -ne $_})
    $annotated=@($windows|Where-Object {$null -ne (Get-QuotaProperty $_ 'windowMinutes')})
    if($annotated.Count -gt 0){
        foreach($window in $windows){
            $minutes=Get-QuotaProperty $window 'windowMinutes'
            if($minutes -eq 300){$fiveWindow=$window}
            elseif($minutes -eq 10080){$weekWindow=$window}
        }
        # Absence is confirmed only by a single explicitly weekly window.
        # A missing/failed/unsupported response must never mean unlimited quota.
        $absent=($windows.Count -eq 1 -and $null -ne $weekWindow)
    }else{
        # Older Switch versions omit duration metadata and use positional fields.
        $fiveWindow=$primary;$weekWindow=$secondary
    }
    $values=@{}
    foreach($name in @('FiveHour','Weekly')){
        $window=if($name -eq 'FiveHour'){$fiveWindow}else{$weekWindow}
        $raw=Get-QuotaProperty $window 'remainingPercent';$number=0.0
        $valid=($null -ne $raw -and [double]::TryParse([string]$raw,[ref]$number) -and
            -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0 -and $number -le 100)
        $values[$name]=$(if($valid){$number}else{$null})
    }
    [pscustomobject]@{
        FiveHour=$values.FiveHour;Weekly=$values.Weekly;FiveHourLimitAbsent=$absent
        FiveHourReset=(Get-QuotaProperty $fiveWindow 'resetsAt');WeeklyReset=(Get-QuotaProperty $weekWindow 'resetsAt')
        UsageError=(Get-QuotaProperty $Usage 'error')
    }
}
function Test-AccountQuotaKnown($Account){
    return (-not (Get-QuotaProperty $Account 'UsageError') -and $null -ne $Account.Weekly -and
        ($null -ne $Account.FiveHour -or (Get-QuotaProperty $Account 'FiveHourLimitAbsent') -eq $true))
}
function Test-AccountQuotaAvailable($Account){
    return ((Test-AccountQuotaKnown $Account) -and $Account.Weekly -gt 0 -and
        ($Account.FiveHour -gt 0 -or (Get-QuotaProperty $Account 'FiveHourLimitAbsent') -eq $true))
}
function Get-AccountPriority($Account,$FallbackIds=@()){
    if((Get-QuotaProperty $Account 'FiveHourLimitAbsent') -eq $true -or $Account.Id -in @($FallbackIds)){return 1}
    return 0
}
function Sort-QuotaAccounts($Accounts,$FallbackIds=@()){
    return @($Accounts|Sort-Object -Property @{Expression={Get-AccountPriority $_ $FallbackIds};Descending=$false},
        @{Expression={$_.Weekly};Descending=$true},@{Expression={$_.FiveHour};Descending=$true})
}
function Format-AccountFiveHour($Account){
    if(Get-QuotaProperty $Account 'UsageError'){return '--'}
    if((Get-QuotaProperty $Account 'FiveHourLimitAbsent') -eq $true){return '无此限制'}
    if($null -eq $Account.FiveHour){return '--'}
    return ('{0:0.#}%' -f $Account.FiveHour)
}
