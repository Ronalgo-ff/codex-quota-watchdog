# Persistent scheduler. Account handling, desktop turns and diagnostics have independent lifecycles.
function Initialize-V2State {
    param($State)
    foreach ($name in @('deliveries','switchIncidents','creditRecoveries')) {
        if (-not (Get-StateFlag $State $name)) { Set-StateFlag $State $name ([pscustomobject]@{}) }
    }
}

function Write-Transition {
    param([string]$Key,[string]$Message,[string]$Level='WARN')
    if (-not (Get-Variable V2Events -Scope Script -ErrorAction SilentlyContinue)) { $script:V2Events=@{} }
    if ($script:V2Events[$Key] -ne $Message) { $script:V2Events[$Key]=$Message; Write-Event $Message $Level }
}

function Get-RecoveryPolicy {
    param([string]$Message)
    # Known service outages can recover without operator intervention.
    if($Message -match '(?i)桌面通道不可用|桌面本地会话状态暂不可用|Desktop pipe|无法连接到远程服务器|无法解析此远程名称|连接超时|连接被拒绝|connection refused|connection reset|name resolution|network is unreachable|timed? out|timeout|超时|\b(408|429|502|503|504)\b|Codex Switch 未返回账号'){
        return 'wait-service'
    }
    if($Message -match '没有唯一当前账号|当前账号额度数据未知|实际读取.+等待完整数据') {return 'wait-data'}
    return 'unknown'
}

function Test-TransientTurnError {
    param([string]$Message)
    return $Message -match '(?i)stream_disconnected|stream disconnected|connection_failed|connection reset|connection refused|network_error|response_timeout|request_timeout|timed? out|\b(502|503|504)\b|temporarily unavailable'
}

function Test-CreditsTurnError {
    param([string]$Message)
    # Match only the structured turn error, never user text, tool output or final summaries.
    return $Message -match '(?i)out[ _]of[ _]credits|insufficient[ _]credits|no credits remaining|add credits to continue|purchase more credits|credit balance.{0,20}(exhausted|insufficient)'
}

function Get-CreditRetryExclusions {
    param($State,$Recent,$FreshHits,$Accounts,$Current)
    foreach($v in $Recent){
        if($v.Outcome -in @('finished','unfinished') -and $State.creditRecoveries.PSObject.Properties[$v.Id]){
            Clear-StateFlag $State.creditRecoveries $v.Id;Save-State $State
        }
    }
    $excluded=@()
    foreach($v in @($FreshHits|Where-Object {Test-CreditsTurnError $_.Error})){
        $r=Get-StateFlag $State.creditRecoveries $v.Id
        if(-not $r){
            $r=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');accounts=[pscustomobject]@{}}
            Set-StateFlag $State.creditRecoveries $v.Id $r
        }
        # One attempt per account in this unresolved credit-failure chain. A real quota
        # increase/reset makes an account eligible again; a restart alone does not.
        foreach($a in $Accounts){
            $old=Get-StateFlag $r.accounts $a.Id
            if($old -and $a.Id -ne $Current.Id -and $null -ne $a.FiveHour -and $null -ne $a.Weekly -and -not $a.UsageError -and
                ($a.FiveHour -gt $old.fiveHour -or $a.Weekly -gt $old.weekly -or
                 ($a.FiveHourReset -gt $old.fiveHourReset -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $old.fiveHourReset))){
                Clear-StateFlag $r.accounts $a.Id
            }
        }
        Set-StateFlag $r.accounts $Current.Id ([pscustomobject]@{turnId=$v.TurnId;fiveHour=$Current.FiveHour;weekly=$Current.Weekly;fiveHourReset=$Current.FiveHourReset})
        $excluded+=@($r.accounts.PSObject.Properties|ForEach-Object {$_.Name})
        Save-State $State
    }
    return @($excluded|Select-Object -Unique)
}

function Get-RolloutInterruptionEvidence {
    param([string]$ThreadId,[string]$TurnId)
    # Desktop can synthesize interrupted/error=null for a lost app-server turn.
    # A real Stop has a turn_aborted record. Require positive evidence of the
    # exact still-open turn; missing files/markers never grant permission.
    $files=@(Get-RecentSessions | Where-Object {$_.BaseName.EndsWith('-'+$ThreadId)})
    if($files.Count -ne 1){return 'unverified'}
    $file=$files[0];$file.Refresh()
    if(-not (Get-Variable InterruptionEvidenceCache -Scope Script -ErrorAction SilentlyContinue)){$script:InterruptionEvidenceCache=@{}}
    $stamp=$TurnId+':'+$file.Length+':'+$file.LastWriteTimeUtc.Ticks
    $cached=$script:InterruptionEvidenceCache[$file.FullName]
    if($cached -and $cached.stamp -eq $stamp){return $cached.result}
    $result='unverified';$reader=$null
    try{
        $reader=New-Object IO.StreamReader([IO.File]::Open($file.FullName,'Open','Read','ReadWrite'),[Text.Encoding]::UTF8)
        $meta=$reader.ReadLine()|ConvertFrom-Json
        if($meta.type -ne 'session_meta' -or $meta.payload.id -ne $ThreadId -or
            $meta.payload.source -ne 'vscode' -or $meta.payload.originator -ne 'Codex Desktop'){return 'unverified'}
        $reader.Dispose();$reader=$null
        $text=Read-FileTailForMarkers $file
        if(-not $text.EndsWith("`n")){return 'unverified'}
        $last=$null;$final=$false
        foreach($match in [regex]::Matches($text,'(?m)^\{"timestamp":[^\r\n]+')){
            $line=$match.Value
            # Inspect envelope types, never marker/error words in tool/user text.
            if($line -notmatch '^\{"timestamp":"[^"]+"[^\r\n]{0,160}?"type":"(event_msg|response_item)","payload":\{"type":"(task_started|task_complete|task_completed|turn_aborted|message)"'){continue}
            $record=$line|ConvertFrom-Json;$p=$record.payload
            if($record.type -eq 'event_msg' -and $p.type -in @('task_started','task_complete','task_completed','turn_aborted')){
                $last=$p;if($p.type -eq 'task_started'){$final=$false}
            }elseif($record.type -eq 'response_item' -and $p.type -eq 'message' -and $p.role -eq 'assistant' -and (Get-StateFlag $p 'phase') -in @('final','final_answer')){$final=$true}
        }
        if($last -and $last.turn_id -eq $TurnId){
            if($last.type -eq 'turn_aborted'){$result='explicit-stop'}
            elseif($last.type -eq 'task_started' -and -not $final){$result='open-turn'}
            else{$result='terminal'}
        }
        $file.Refresh()
        if($stamp -ne ($TurnId+':'+$file.Length+':'+$file.LastWriteTimeUtc.Ticks)){return 'unverified'}
        $script:InterruptionEvidenceCache[$file.FullName]=@{stamp=$stamp;result=$result}
    }catch{return 'unverified'}finally{if($reader){$reader.Dispose()}}
    return $result
}

function Get-TurnView {
    param([string]$ThreadId)
    $data=Invoke-DesktopTool 'read_thread' @{threadId=$ThreadId;hostId='local';turnLimit=1;includeOutputs=$false;maxOutputCharsPerItem=0}
    $turn=@($data.turns | Select-Object -First 1)
    $status=$data.thread.status.type
    $view=[pscustomobject]@{Id=$ThreadId;Status=$status;TurnId='';Outcome='finished';Reason='';Final='';User='';At=[double]$data.thread.updatedAt;StartedEpoch=0;DesktopMessage=$false;Error='';Raw=$data}
    if ($turn.Count -eq 0) { return $view }
    $t=$turn[0]; $view.TurnId=[string]$t.id
    $view.StartedEpoch=[double](Get-StateFlag $t 'startedAt')
    $view.DesktopMessage=@($t.items|Where-Object {$_.type -eq 'functionCallOutput' -and (Get-StateFlag $_ 'name') -eq 'send_message_to_thread' -and (Get-StateFlag $_ 'namespace') -eq 'codex_app'}).Count -gt 0
    $view.Error=($t.error | ConvertTo-Json -Depth 8 -Compress)
    $view.Final=(@($t.items | Where-Object {$_.type -eq 'agentMessage' -and (Get-StateFlag $_ 'phase') -in @('final_answer','final')} | ForEach-Object {$_.text}) -join "`n")
    $view.User=(@($t.items | Where-Object {$_.type -eq 'userMessage'} | ForEach-Object {$_.content} | Where-Object {$_.type -eq 'text'} | ForEach-Object {$_.text}) -join "`n")
    $flags=@(Get-StateFlag $data.thread.status 'activeFlags') -join ','
    if ($flags -match 'waiting|approval|input' -or $status -match 'waiting|approval') { $view.Outcome='waiting'; return $view }
    if ($status -in @('active','running','inProgress')) { $view.Outcome='running'; return $view }
    if ($view.User -match '(?i)(不要|不必|不用|停止|暂停).{0,12}(继续|执行|运行|工作|任务)|先等我|等我(确认|回复)|\b(stop|pause)\b') {
        $view.Outcome='waiting'; return $view
    }
    if ($view.Error -match '(?i)usage_limit_exceeded|usage limit|hit your usage limit|quota' -or (Test-CreditsTurnError $view.Error)) { $view.Outcome='limit'; return $view }
    if ($t.status -in @('interrupted','aborted')) {
        $view.Outcome=if(Test-TransientTurnError $view.Error){'retryable'}else{'waiting'}
        if($view.Outcome -eq 'waiting'){
            $view.Reason=Get-RolloutInterruptionEvidence $ThreadId $view.TurnId
            if($t.status -eq 'interrupted' -and $view.Reason -eq 'open-turn' -and
                -not $view.Final -and [string]$view.Error -in @('','null','""')){
                $view.Outcome='interrupted'
            }
        }
        return $view
    }
    if ($t.status -in @('inProgress','running') -and $status -eq 'notLoaded') { $view.Outcome='interrupted'; return $view }
    if ($t.status -eq 'failed') {
        $view.Outcome=if(Test-TransientTurnError $view.Error){'retryable'}else{'unknown'}
        return $view
    }
    # A completed summary/report is complete even if it describes unfinished historical work.
    if ($view.User -match '(?i)总结|汇总|写成一段|交接|概括|翻译|改写|润色|summari[sz]e|translate') { return $view }
    if ($view.Final -match '(?i)等(待)?你|请(你)?(确认|选择|提供|回复|批准)|需要(你|用户).{0,8}(确认|提供|选择)|awaiting.{0,20}(input|approval)|waiting for you') {
        $view.Outcome='waiting'; return $view
    }
    # Only explicit claims about the current work; arbitrary substring matching caused false resumes.
    if ($view.Final -match '(?i)(工作|任务|功能|实现|修改|修复|测试|验证|这次|目前|现在|仍然|仍|还|尚|我|本次|当前|这项).{0,8}(尚未完成|还没完成|没有完成|没做完|未做完|尚未做完|还没做完)|\b(I have not finished|work is unfinished|task is incomplete|still not complete)\b') {
        $view.Outcome='unfinished'
    }
    return $view
}

function Get-LocalDesktopThreads {
    # The desktop list can lag newly created threads; discover from genuine local metadata.
    $seen=@{}
    foreach($file in @(Get-RecentSessions)){
        $reader=$null
        try{
            $stream=[IO.File]::Open($file.FullName,'Open','Read','ReadWrite')
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
            $meta=$reader.ReadLine()|ConvertFrom-Json
            $source=Get-StateFlag $meta.payload 'source'
            if($meta.type -ne 'session_meta' -or $source -ne 'vscode' -or (Get-StateFlag $meta.payload 'originator') -ne 'Codex Desktop'){continue}
            $id=[string]$meta.payload.id
            if(-not $id -or $seen.ContainsKey($id)){continue}
            $seen[$id]=$true
            [pscustomobject]@{id=$id;kind='codex';hostId='local';status='discovered';updatedAt=([DateTimeOffset](Get-SessionFileStamp $file)).ToUnixTimeSeconds()}
        }catch{Write-File "会话索引暂不可读：$($file.Name)" 'WARN'}finally{if($reader){$reader.Dispose()}}
    }
}

$script:DesktopListingCache=@()
$script:DesktopListingRetryAt=[datetime]::MinValue
$script:DesktopHealth=[pscustomobject]@{mode='starting';at=(Get-Date).ToString('o');error=$null}
function Get-DesktopSnapshot {
    $fallback=(Get-Date) -lt $script:DesktopListingRetryAt
    $listed=@($script:DesktopListingCache)
    if(-not $fallback){
        try{
            $listing=Invoke-DesktopTool 'list_threads' @{limit=50}
            if (@(Get-StateFlag $listing 'unavailableHosts') -contains 'local') { throw '桌面本地会话状态暂不可用' }
            $listed=@(@($listing.pinnedThreads)+@($listing.threads) | Where-Object {$_.kind -eq 'codex' -and $_.hostId -eq 'local'})
            $script:DesktopListingCache=$listed
        }catch{
            $fallback=$true;$script:DesktopListingRetryAt=(Get-Date).AddSeconds(60)
            $script:DesktopHealth=[pscustomobject]@{mode='degraded';at=(Get-Date).ToString('o');error=$_.Exception.Message}
        }
    }
    $local=@(Get-LocalDesktopThreads)
    $threads=@(@($listed)+$local |
        Sort-Object updatedAt -Descending | Group-Object id | ForEach-Object {$_.Group[0]} | Sort-Object updatedAt -Descending)
    if($fallback -and $local.Count -eq 0){throw '桌面列表超时且本地会话索引为空，无法安全核实运行状态'}
    $recent=@();$active=@();$views=@{}
    try{
        foreach($t in @($threads|Select-Object -First 5)){
            $v=Get-TurnView $t.id;$views[$t.id]=$v;$recent+=$v
        }
        if($fallback){
            # Protect older active work too. Local metadata only discovers identity;
            # read_thread is authoritative. Never infer idle from file inactivity.
            $verify=@(@($local)+@($listed|Where-Object {$_.status -in @('active','running','inProgress')})|Group-Object id|ForEach-Object {$_.Group[0]})
            foreach($t in $verify){if(-not $views.ContainsKey($t.id)){$views[$t.id]=Get-TurnView $t.id}}
            foreach($v in $views.Values){if($v.Status -in @('active','running','inProgress')){$active+=[pscustomobject]@{id=$v.Id;status=$v.Status}}}
            Write-Transition 'desktop-list-fallback' '会话列表暂不可用，已改用本地索引并逐条核实桌面状态；切号和续跑检查继续（后续通道状态见底部）' 'WARN'
            $script:DesktopHealth=[pscustomobject]@{mode='fallback';at=(Get-Date).ToString('o');error=$null}
        }else{
            $active=@($listed|Where-Object {$_.status -in @('active','running','inProgress')})
            foreach($v in $recent){if($v.Outcome -in @('running','waiting') -and $v.Status -in @('active','running','inProgress') -and $v.Id -notin @($active|ForEach-Object {$_.id})){$active+=[pscustomobject]@{id=$v.Id;status=$v.Status}}}
            # Healthy/fallback route changes are reflected in the footer, not repeated events.
            $script:DesktopHealth=[pscustomobject]@{mode='ok';at=(Get-Date).ToString('o');error=$null}
        }
    }catch{
        $script:DesktopHealth=[pscustomobject]@{mode='unavailable';at=(Get-Date).ToString('o');error=$_.Exception.Message}
        throw
    }
    return [pscustomobject]@{Recent=$recent;Active=$active;Views=$views}
}

function Update-DesktopDeliveries {
    param($State,$Views=@{})
    if(-not $Views){$Views=@{}}
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach($entry in @($State.deliveries.PSObject.Properties)) {
        $d=$entry.Value
        if($d.phase -in @('completed','failed')) {continue}
        # A superseded submission can be reconciled inside its original 120s
        # evidence window. After that it is settled, never replayed or polled.
        if($d.phase -eq 'superseded' -and $now -gt $d.sentEpoch+120){continue}
        try{
            if($Views -and $Views.ContainsKey($d.threadId)){$v=$Views[$d.threadId]}
            else{$v=Get-TurnView $d.threadId;$Views[$d.threadId]=$v}
        }catch{
            Write-Transition ('delivery-read:'+ $d.threadId) "暂时无法核对对话 $($d.threadId.Substring(0,8)) 的续跑结果；额度看护继续" 'WARN'
            continue
        }
        # Migrate only the exact historical pre-dispatch rejection with no receipt.
        # Never reopen acknowledged, timed-out, superseded or completed deliveries.
        if($d.phase -eq 'uncertain' -and $d.error -eq 'App-server task is not ready: execution-config-loading' -and
            -not (Get-StateFlag $d 'receipt') -and -not $State.handled.PSObject.Properties[$entry.Name]){
            $d.phase='deferred';Set-StateFlag $d 'nextAttemptEpoch' ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+[int]$Script:Config.DesktopConfigRetrySec);Save-State $State
        }
        if($d.phase -eq 'deferred'){
            if($v.TurnId -ne $d.sourceTurnId){$d.phase='superseded';Save-State $State}
            continue # The main recent-five selector will retry only after a fresh safety check.
        }
        $desktopEvidence=(Get-StateFlag $v 'DesktopMessage') -eq $true -and [double](Get-StateFlag $v 'StartedEpoch') -ge $d.sentEpoch-2 -and [double](Get-StateFlag $v 'StartedEpoch') -le $d.sentEpoch+120
        if($d.phase -eq 'superseded' -and -not $desktopEvidence){continue}
        if($v.TurnId -ne $d.sourceTurnId -and ($v.User.Trim() -eq $Script:Config.ResumeMessage -or $desktopEvidence) -and $v.At -ge $d.sentEpoch-2) {
            if($d.phase -ne 'started') { Write-Event "续跑已确认开始：$($d.threadId.Substring(0,8))，桌面回合 $($v.TurnId)" 'OK' }
            $d.phase='started'
            if($v.Outcome -notin @('running','waiting')) {
                $d.phase=if($v.Outcome -in @('limit','unknown','retryable','interrupted')){'failed'}else{'completed'}
                Write-Event "续跑回合已结束：$($d.threadId.Substring(0,8))，结果 $($v.Outcome)" $(if($d.phase -eq 'failed'){'WARN'}else{'OK'})
            }
            Set-StateFlag $d 'observedTurnId' $v.TurnId
            Save-State $State
        } elseif($v.TurnId -ne $d.sourceTurnId -and $v.At -ge $d.sentEpoch-2) {
            $d.phase='superseded'; Save-State $State
        } elseif(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$d.sentEpoch) -gt 120) {
            if($d.phase -ne 'uncertain') {
                $d.phase='uncertain'; Save-State $State
                Write-Event "续跑未确认开始：$($d.threadId.Substring(0,8))；保存现场且不重复发送" 'WARN'
            }
            Request-ManualPause $State ('delivery:'+ $entry.Name) '桌面续跑提交结果不确定' $d
        }
    }
}

function Test-LegacyIncidentHandled {
    param($State,$View)
    foreach($file in @(Get-RecentSessions | Where-Object {$_.Name.Contains($View.Id)})){
        $fact=Get-SessionFact $file
        if($State.handled.PSObject.Properties[(Get-ResumeFingerprint $fact)]){return $true}
        if($View.Outcome -eq 'limit' -and $State.handled.PSObject.Properties[(Get-LimitFingerprint $fact)]){return $true}
    }
    return $false
}

function Get-ResumeAccountProof {
    param($State)
    if(Get-StateFlag $State 'switchIntent'){return $null}
    $wait=Get-StateFlag $State 'waitingReset'
    if($wait -and $wait.phase -ne 'success'){return $null}
    try{$accounts=@(Get-Accounts)}catch{
        if((Get-RecoveryPolicy $_.Exception.Message) -eq 'unknown'){throw}
        Write-Transition 'resume-quota-check' '续跑前额度暂时无法核实，本轮不发送继续' 'WARN'
        return $null
    }
    $active=@($accounts|Where-Object {$_.Active})
    if($accounts.Count -ne $Script:Config.ExpectedAccounts -or $active.Count -ne 1){return $null}
    $a=$active[0]
    if($a.UsageError -or $null -eq $a.FiveHour -or $null -eq $a.Weekly -or $a.FiveHour -le 0 -or $a.Weekly -le 0){
        Write-Transition 'resume-quota-check' '续跑前复查发现当前账号无可用额度或数据未知；不发送继续，交回切号/等待流程' 'WARN'
        return $null
    }
    return [pscustomobject]@{accountId=$a.Id;fiveHour=$a.FiveHour;weekly=$a.Weekly;checkedAt=(Get-Date).ToString('o')}
}

function Send-DesktopContinue {
    param($State,$View)
    $key='desktop:'+$View.Id+':'+$View.TurnId
    if($State.handled.PSObject.Properties[$key]) {return}
    $existing=Get-StateFlag $State.deliveries $key
    if($existing -and $existing.phase -ne 'deferred'){return}
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if($existing -and $now -lt [double](Get-StateFlag $existing 'nextAttemptEpoch')){return}
    $readyAfter=Get-StateFlag $State 'desktopReadyAfter'
    if($readyAfter -and (Get-Date) -lt [datetime]::Parse($readyAfter)){
        Write-Transition ('resume-ready:'+ $View.Id) "切号已确认；缓冲 $($Script:Config.DesktopReadyDelaySec) 秒后核实并尝试继续 $($View.Id.Substring(0,8))" 'INFO'
        return
    }
    # Re-read immediately before submission to close the polling/dispatch race.
    $fresh=Get-TurnView $View.Id
    if($fresh.TurnId -ne $View.TurnId -or $fresh.Outcome -notin @('interrupted','unfinished','limit','retryable')) {
        if($existing -and $fresh.TurnId -ne $View.TurnId){$existing.phase='superseded';Save-State $State}
        return
    }
    if(-not $Live) {Write-Transition $key "[演习] 会通过桌面继续 $($View.Id.Substring(0,8))" 'DRYRUN';return}
    $quotaProof=Get-ResumeAccountProof $State
    if(-not $quotaProof){return}
    $attempts=1;if($existing){$attempts=1+[int](Get-StateFlag $existing 'attempts')}
    $delivery=[pscustomobject]@{threadId=$View.Id;sourceTurnId=$View.TurnId;sentEpoch=$now;phase='sending';error=$null;attempts=$attempts;quotaProof=$quotaProof} 
    $State.deliveries | Add-Member -NotePropertyName $key -NotePropertyValue $delivery -Force
    # Write-ahead intent: after a crash or lost response this incident cannot be sent twice.
    Save-State $State
    try {
        $reply=Invoke-DesktopTool 'send_message_to_thread' @{threadId=$View.Id;hostId='local';prompt=$Script:Config.ResumeMessage}
        $delivery.phase='accepted'; Set-StateFlag $delivery 'receipt' $reply
        $State.handled | Add-Member -NotePropertyName $key -NotePropertyValue ((Get-Date).ToString('o')) -Force
        Save-State $State
        Write-Event "桌面已接收继续：$($View.Id.Substring(0,8))；等待新回合证据" 'INFO'
    } catch {
        if($_.Exception.Data['QuotaPreDispatchRejected'] -eq $true){
            $delivery.phase='deferred';$delivery.error=$_.Exception.Message
            $retrySec=if($attempts -lt 4){[int]$Script:Config.DesktopConfigRetrySec}else{[Math]::Max(60,[int]$Script:Config.DesktopConfigRetrySec)}
            # Count from the rejection receipt, not the request start. Only this
            # proven pre-dispatch failure permits another submission.
            Set-StateFlag $delivery 'nextAttemptEpoch' ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+$retrySec)
            Save-State $State
            Write-Transition ('resume-deferred:'+ $View.Id) "桌面配置仍在加载，继续请求被明确拒绝；$retrySec 秒后核实会话并重试：$($View.Id.Substring(0,8))" 'WARN'
            if($attempts -ge 8){Request-ManualPause $State ('resume-config:'+ $key) '桌面配置长时间未就绪，暂停等待人工处理' $delivery}
            return
        }
        $delivery.phase='uncertain';$delivery.error=$_.Exception.Message;Save-State $State
        Write-Event "续跑提交未确认：$($View.Id.Substring(0,8))；不会重复发送。$($delivery.error)" 'WARN'
        Request-ManualPause $State $key '桌面续跑未确认' $delivery
    }
}

function Start-QuotaBatch {
    param($State,$Accounts)
    $wait=$State.waitingReset
    if(-not $Live){return}
    $id=[guid]::NewGuid().ToString('N');$dir=Join-Path $Script:Config.StateDir 'quota-batches'
    $null=New-Item -ItemType Directory -Path $dir -Force
    $job=Join-Path $dir ($id+'.json')
    $batch=[ordered]@{id=$id;source='watcher-reset';coordinationDir=(Join-Path $Script:Config.StateDir 'quota-coordination');waitPolicy=$Script:Config.ResetWaitPolicy;endpoint=$Script:Config.CswEndpoint;startedAt=(Get-Date).ToString('o');phase='prepared';accounts=@($Accounts|ForEach-Object {@{id=$_.Id;phase='pending';error=$null}})}
    Write-JsonAtomic $job $batch
    Set-StateFlag $wait 'phase' 'running';Set-StateFlag $wait 'batchFile' $job;Save-State $State
    . (Join-Path $PSScriptRoot 'process.ps1')
    $runner=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\quota-batch.ps1'))
    $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$runner,'-JobFile',$job)
    $proc=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList (($args|ForEach-Object {ConvertTo-NativeArgument $_})-join ' ') -WindowStyle Hidden -PassThru
    Set-StateFlag $wait 'pid' $proc.Id; Set-StateFlag $wait 'processStartedAt' $proc.StartTime.ToString('o');Save-State $State
    Write-Event "进入恢复批次；对当前可用账号各尝试消耗一次并保存回执（批次 $($id.Substring(0,8))）" 'INFO'
}

function Invoke-ResetCycle {
    param($State,$Accounts)
    $wait=Get-StateFlag $State 'waitingReset'
    $policy=[string]$Script:Config.ResetWaitPolicy
    $waitAll=$policy -eq 'all'
    $weeklyOnly=$policy -eq 'weekly-eligible'
    $ready=@($Accounts|Where-Object {$null -ne $_.FiveHour -and $null -ne $_.Weekly -and $_.FiveHour -gt 0 -and $_.Weekly -gt 0 -and -not $_.UsageError})
    if(-not $wait -and $ready.Count -gt 0){return 'none'}
    $weeklyTargets=@($Accounts|Where-Object {$null -ne $_.Weekly -and $_.Weekly -gt 0 -and -not $_.UsageError})
    $unknown=@($Accounts|Where-Object {$_.UsageError -or $null -eq $_.Weekly -or ($null -eq $_.FiveHour -and (-not $weeklyOnly -or $_.Weekly -gt 0))})
    if($Accounts.Count -ne $Script:Config.ExpectedAccounts -or ($unknown.Count -gt 0 -and (-not $wait -or (($waitAll -or $weeklyOnly) -and $wait.phase -eq 'waiting')))){
        Write-Transition 'reset-unknown' '账号数量或额度数据不完整，等待重新读取；不会批量消耗'
        return 'waiting'
    }
    if(-not $wait){
        $plan=Get-WaitPlan $Accounts 'all'
        $wait=[pscustomobject]@{phase='waiting';since=(Get-Date).ToString('o');wakeAt=$plan.WakeAt.ToString('o');accountIds=@($Accounts|ForEach-Object {$_.Id})}
        Set-StateFlag $State 'waitingReset' $wait; Save-State $State
        if($weeklyOnly){Write-Event '全部账号均不可用；排除周额度耗尽账号，等待其余账号五小时额度全部恢复' 'WARN'}
        elseif($waitAll){Write-Event "全部账号均不可用，等待所有账号刷新，最早检查消耗时间 $($plan.WakeAt.ToString('MM-dd HH:mm:ss'))" 'WARN'}
        else{Write-Event '全部账号均不可用；持续监控，有账号恢复可用即尝试消耗并恢复调度' 'WARN'}
        return 'waiting'
    }
    if((@($wait.accountIds|Sort-Object)-join ',') -ne (@($Accounts.Id|Sort-Object)-join ',')){
        Request-ManualPause $State 'reset-accounts-changed' '等待期间账号集合改变，已冻结批量消耗' $wait
        return 'waiting'
    }
    if($wait.phase -in @('running','failed')){
        $jobPath=Get-StateFlag $wait 'batchFile'
        if(-not $jobPath -or -not (Test-Path -LiteralPath $jobPath)){
            Request-ManualPause $State 'reset-legacy-uncertain' '旧批量消耗状态不确定，禁止自动重试' $wait
            return 'waiting'
        }
        $batch=Get-Content -LiteralPath $jobPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($batch.phase -eq 'preflight-retry' -and @($batch.accounts).Count -eq $Accounts.Count -and
            (@($batch.accounts.id|Sort-Object)-join ',') -eq (@($Accounts.Id|Sort-Object)-join ',') -and
            @($batch.accounts|Where-Object {$_.phase -ne 'pending'}).Count -eq 0){
            $wait.phase='waiting';Set-StateFlag $wait 'wakeAt' ((Get-Date).AddSeconds(60).ToString('o'));Set-StateFlag $wait 'retryAfter' $wait.wakeAt
            Clear-StateFlag $wait 'batchFile';Save-State $State
            Write-Transition 'batch-preflight-retry' '消耗前读取账号暂时失败，尚未发送消耗请求；60 秒后重新检查全部账号'
            return 'waiting'
        }
        if($batch.phase -eq 'not-ready' -and @($batch.accounts|Where-Object {$_.phase -ne 'pending'}).Count -eq 0){
            $plan=Get-WaitPlan $Accounts 'all'
            $wait.phase='waiting';$wait.wakeAt=$plan.WakeAt.ToString('o');Set-StateFlag $wait 'retryAfter' ((Get-Date).AddSeconds(60).ToString('o'))
            Clear-StateFlag $wait 'batchFile';Save-State $State
            Write-Transition 'batch-not-ready' '消耗前复查发现暂无可用账号；尚未发送消耗请求，60 秒后重新检查'
            return 'waiting'
        }
        $alive=$false
        $jobPid=Get-StateFlag $wait 'pid';$at=Get-StateFlag $wait 'processStartedAt'
        if($jobPid -and $at){try{$p=Get-Process -Id $jobPid -ErrorAction Stop;$alive=[Math]::Abs(($p.StartTime-[datetime]::Parse($at)).TotalSeconds)-lt 2}catch{}}
        # Let the worker finish its one pass before changing accounts/restarting Codex.
        if($alive -and $batch.phase -in @('prepared','running')){return 'waiting'}
        $receipts=@($batch.accounts)
        $successes=@($receipts|Where-Object {$_.phase -eq 'success'})
        if($successes.Count -gt 0){
            if($receipts.Count -ne $Accounts.Count -or
                (@($receipts|ForEach-Object {$_.id}|Sort-Object)-join ',') -ne (@($Accounts.Id|Sort-Object)-join ',')){
                Request-ManualPause $State ('batch-invalid:'+ $batch.id) '批量消耗账号回执不匹配，不能确认本批结果' $batch
                return 'waiting'
            }
            $usableSuccess=@($ready|Where-Object {$_.Id -in @($successes.id) -and $_.FiveHourReset -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()})
            if($usableSuccess.Count -eq 0){
                Write-Transition 'timer-verify' '已有消耗成功回执，等待至少一个成功账号的可用额度与五小时计时确认；不重复消耗'
                return 'waiting'
            }
            $wait.phase='success';Save-State $State
            $remaining=$receipts.Count-$successes.Count
            Write-Event "本批消耗成功 $($successes.Count) 个，未确认成功或跳过 $remaining 个；已有可用账号计时有效，恢复选号与续跑，不重试未确认消耗" 'OK'
            return 'recovered'
        }
        $wait.phase='failed';Save-State $State
        Request-ManualPause $State ('batch:'+ $batch.id) '本批没有账号确认消耗成功；保留逐账号状态，禁止重复扣额度' $batch
        return 'waiting'
    }
    if($wait.phase -eq 'success'){
        if($ready.Count -eq 0){
            Clear-StateFlag $State 'waitingReset';Save-State $State
            return (Invoke-ResetCycle $State $Accounts)
        }
        return 'recovered'
    }
    if($weeklyOnly){
        $ids=@($weeklyTargets|ForEach-Object {$_.Id}|Sort-Object)
        $oldIds=@(Get-StateFlag $wait 'eligibleIds')
        if(($ids -join ',') -ne ($oldIds -join ',') -or (Get-StateFlag $wait 'waitPolicy') -ne $policy){
            Set-StateFlag $wait 'eligibleIds' $ids
            Set-StateFlag $wait 'waitPolicy' $policy
            # Historical wakeAt may be a weekly reset several days away. The new
            # rule is based on current quotas, not that obsolete prediction.
            Clear-StateFlag $wait 'wakeAt';Save-State $State
        }
        if($weeklyTargets.Count -eq 0){
            Write-Transition 'reset-wait-status' '所有账号周额度均已耗尽；等待周额度恢复，不消耗、不切号' 'INFO'
            return 'waiting'
        }
        $pending=@($weeklyTargets|Where-Object {$_.FiveHour -le 0})
        if($pending.Count -gt 0){
            $last=@($pending|Where-Object {$_.FiveHourReset -gt 0}|Sort-Object FiveHourReset -Descending|Select-Object -First 1)
            $estimate=if($last.Count){Format-ResetAt $last[0].FiveHourReset}else{'未知'}
            Write-Transition 'reset-wait-status' "等待五小时恢复：周额度可用 $($weeklyTargets.Count) 个，已就绪 $($weeklyTargets.Count-$pending.Count) 个；最后预计 $estimate，实际全部恢复后消耗" 'INFO'
            return 'waiting'
        }
        $retryAfter=Get-StateFlag $wait 'retryAfter'
        if($retryAfter -and (Get-Date) -lt [datetime]::Parse($retryAfter)){return 'waiting'}
    }elseif($waitAll){
        $notice=Get-StateFlag $wait 'wakeAt'
        Write-Transition 'reset-wait-status' "等待全部账号刷新：当前 $($ready.Count)/$($Accounts.Count) 个可用；最早消耗时间 $notice，暂不切号续跑" 'INFO'
        if($ready.Count -ne $Accounts.Count){return 'waiting'}
        if((Get-Date) -lt [datetime]::Parse($wait.wakeAt)){return 'waiting'}
    }else{
        if($ready.Count -eq 0){Write-Transition 'reset-wait-status' '等待账号恢复：当前无可用账号；任一账号恢复后即进入消耗与续跑' 'INFO';return 'waiting'}
        # Old all-account wakeAt may be days away. Only an actual retry backoff
        # constrains the new any-ready policy; migration never erases delivery receipts.
        $retryAfter=Get-StateFlag $wait 'retryAfter'
        if($retryAfter -and (Get-Date) -lt [datetime]::Parse($retryAfter)){return 'waiting'}
    }
    if(-not $Live){Write-Transition 'dry-batch' '[演习] 会对当前可用账号尝试消耗一次，再恢复选号续跑' 'DRYRUN';return 'waiting'}
    Start-QuotaBatch $State $Accounts
    return 'waiting'
}

function Invoke-WatchRound {
    param($State)
    Initialize-V2State $State
    $accounts=@(Get-Accounts)
    # Publish even while waiting for all resets or while the desktop is unavailable.
    # A display snapshot never writes events and cannot initiate account operations.
    $displayActive=@($accounts|Where-Object {$_.Active})
    $quotaFile=Join-Path $Script:Config.StateDir $(if($Live){'quota-status.json'}else{'quota-status.dry-run.json'})
    Write-JsonAtomic $quotaFile @{
        pid=$PID;at=(Get-Date).ToString('o');pollSeconds=$Script:Config.PollSeconds
        account=$(if($displayActive.Count -eq 1){$displayActive[0]|Select-Object Id,FiveHour,Weekly,UsageError}else{$null})
        waitingReset=(Get-StateFlag $State 'waitingReset')
        weeklyEligibleAccounts=@($accounts|Where-Object {-not $_.UsageError -and $null -ne $_.Weekly -and $_.Weekly -gt 0}).Count
        desktopHealth=$script:DesktopHealth
        resetWaitPolicy=$Script:Config.ResetWaitPolicy
        usableAccounts=@($accounts|Where-Object {-not $_.UsageError -and $null -ne $_.FiveHour -and $null -ne $_.Weekly -and $_.FiveHour -gt 0 -and $_.Weekly -gt 0}).Count
    }
    if($accounts.Count -eq 0){throw 'Codex Switch 未返回账号'}
    if($accounts.Count -ne $Script:Config.ExpectedAccounts){throw "预期 $($Script:Config.ExpectedAccounts) 个账号，实际读取 $($accounts.Count) 个；等待完整数据"}
    $cycle=Invoke-ResetCycle $State $accounts
    if($cycle -eq 'waiting'){return}
    $active=@($accounts|Where-Object {$_.Active})
    if($active.Count -ne 1){throw 'Codex Switch 没有唯一当前账号'}
    $a=$active[0]
    # An incomplete quota snapshot is not a zero balance.
    if($null -eq $a.FiveHour -or $null -eq $a.Weekly -or $a.UsageError){throw '当前账号额度数据未知'}
    # Reconcile before reading the desktop, which may still be closed.
    $restartIntent=Get-StateFlag $State 'switchIntent'
    if($restartIntent -and $restartIntent.targetId -eq $a.Id){Set-CodexDesktopRecovery $State $restartIntent}
    if(-not(Test-CodexDesktopRecovery $State $a.Id)){return}
    $snapshot=Get-DesktopSnapshot
    if(Get-StateFlag $State 'desktopRestart'){
        Clear-StateFlag $State 'desktopRestart';Save-State $State
        Write-Event 'Codex 桌面已重新打开，聊天读取通道恢复正常' 'OK'
    }
    $recent=@($snapshot.Recent)
    # Fresh recent-task reads come first; reuse them for pending deliveries.
    # Reconcile uncertain submissions before any account mutation or new send.
    Update-DesktopDeliveries $State -Views (Get-StateFlag $snapshot 'Views')
    $observation=Join-Path $Script:Config.StateDir $(if($Live){'last-observation.json'}else{'last-observation.dry-run.json'})
    Write-JsonAtomic $observation @{
        at=(Get-Date).ToString('o');engine=2;activeAccount=$a.Id
        accounts=@($accounts|Select-Object Id,Active,FiveHour,Weekly,FiveHourReset,WeeklyReset)
        recent=@($recent|Select-Object Id,TurnId,Status,Outcome,Reason,At,Error)
    }
    foreach($v in @($recent|Where-Object {$_.Outcome -eq 'unknown'})){
        Request-ManualPause $State ('turn:'+ $v.Id+':'+$v.TurnId) '会话错误超出现有规则，暂停等待人工处理' @{thread=$v.Id;turn=$v.TurnId;error=$v.Error}
    }
    $hits=@($recent|Where-Object {$_.Outcome -eq 'limit'})
    $freshHits=@($hits|Where-Object {-not $State.switchIncidents.PSObject.Properties[($_.Id+':'+$_.TurnId)] -and
        -not (Test-LegacyIncidentHandled $State $_)})
    $dry=($a.FiveHour -le 0 -or $a.Weekly -le 0)
    $mustSwitch=$dry -or $freshHits.Count -gt 0 -or $cycle -eq 'recovered'
    $intent=Get-StateFlag $State 'switchIntent'
    if($intent){
        if($intent.targetId -eq $a.Id){
            foreach($key in @($intent.incidents)){$State.switchIncidents|Add-Member -NotePropertyName $key -NotePropertyValue $a.Id -Force}
            Clear-StateFlag $State 'switchIntent';Save-State $State
            Set-StateFlag $State 'desktopReadyAfter' ((Get-Date).AddSeconds([int]$Script:Config.DesktopReadyDelaySec).ToString('o'));Save-State $State
            Write-Event "切号已核实生效：$($a.Email)" 'OK'
            $mustSwitch=$dry
        }else{
            Request-ManualPause $State ('switch:'+ $intent.id) '切号结果未确认；不重复发送重启命令' $intent
            return
        }
    }
    $unresolvedHits=@($freshHits|Where-Object {-not $State.switchIncidents.PSObject.Properties[($_.Id+':'+$_.TurnId)]})
    if($cycle -eq 'recovered'){
        # A verified successful batch is stronger recovery evidence than an old
        # credits failure. Do not attribute the old turn to a newly reset account.
        if(@($State.creditRecoveries.PSObject.Properties).Count -gt 0){
            Set-StateFlag $State 'creditRecoveries' ([pscustomobject]@{});Save-State $State
        }
        $creditExcluded=@()
    }else{$creditExcluded=@(Get-CreditRetryExclusions $State $recent $unresolvedHits $accounts $a)}
    if($mustSwitch){
        $hitIds=@($hits | ForEach-Object {$_.Id})
        $blocked=@($snapshot.Active | Where-Object {$_.id -notin $hitIds})
        $waiting=@($recent|Where-Object {$_.Outcome -eq 'waiting' -and $_.Status -in @('active','running','inProgress')})
        if($blocked.Count -gt 0 -or $waiting.Count -gt 0){
            $reason=if($cycle -eq 'recovered'){'消耗已确认，准备选择周额度最高的账号'}else{'额度不足'}
            Write-Transition 'switch-blocked' "$reason，另有 $($blocked.Count) 条对话仍在运行；等待它们结束后切号"
            return
        }
        $candidates=@($accounts|Where-Object {$_.Id -notin $creditExcluded})
        if($creditExcluded.Count -gt 0 -and @($candidates|Where-Object {-not $_.Active -and $_.Switchable -and -not $_.UsageError -and $_.FiveHour -gt 0 -and $_.Weekly -gt 0}).Count -eq 0){
            Write-Transition 'credits-no-candidate' '额度错误在已尝试账号中仍未恢复，当前无未尝试的可用账号；停止循环切号，继续监控额度刷新'
            foreach($v in @($freshHits|Where-Object {Test-CreditsTurnError $_.Error})){
                $recovery=Get-StateFlag $State.creditRecoveries $v.Id
                Request-ManualPause $State ('credits:'+ $recovery.id) '可用账号经过有限切换仍返回 credits 错误' @{thread=$v.Id;error=$v.Error;attempted=$recovery;accounts=@($accounts|Select-Object Id,Active,FiveHour,Weekly,FiveHourReset)}
            }
            return
        }
        $best=(Select-BestAccount $candidates).Best
        # After a reset, keep the current account if it already has the highest weekly quota.
        if($cycle -eq 'recovered' -and -not $dry -and (-not $best -or $a.Weekly -gt $best.Weekly -or ($a.Weekly -eq $best.Weekly -and $a.FiveHour -ge $best.FiveHour))){$best=$null;$mustSwitch=$false}
        if(-not $best -and $mustSwitch){Write-Transition 'no-switchable' '额度不足，暂时没有可切账号；继续等待';return}
        if($best){
            if(-not $Live){Write-Transition 'dry-switch' "[演习] 会切换到 $($best.Email)，周剩余 $($best.Weekly)%" 'DRYRUN';return}
            $intent=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');sourceId=$a.Id;targetId=$best.Id;at=(Get-Date).ToString('o');incidents=@($freshHits|ForEach-Object {$_.Id+':'+$_.TurnId})}
            $desktopLaunch=Get-CodexDesktopLaunch
            if($desktopLaunch){Set-StateFlag $intent 'desktopLaunch' $desktopLaunch}
            Set-StateFlag $State 'switchIntent' $intent;Save-State $State
            if(-not (Invoke-SwitchAccount $best)){Request-ManualPause $State ('switch:'+ $intent.id) '切号结果未确认，已暂停' $intent;return}
            Set-CodexDesktopRecovery $State $intent
            foreach($key in $intent.incidents){$State.switchIncidents|Add-Member -NotePropertyName $key -NotePropertyValue $best.Id -Force}
            Clear-StateFlag $State 'switchIntent';Save-State $State
            Set-StateFlag $State 'desktopReadyAfter' ((Get-Date).AddSeconds([int]$Script:Config.DesktopReadyDelaySec).ToString('o'));Save-State $State
            if($cycle -eq 'recovered'){Clear-StateFlag $State 'waitingReset';Save-State $State}
            # Desktop just restarted. Re-read the recent five next round instead of sending stale selections.
            return
        }
    }
    if($cycle -eq 'recovered'){
        # The current account may already be the best after all windows recovered.
        # Its old quota errors must not force a needless second switch next round.
        foreach($v in $hits){$State.switchIncidents|Add-Member -NotePropertyName ($v.Id+':'+$v.TurnId) -NotePropertyValue $a.Id -Force}
        Clear-StateFlag $State 'waitingReset';Save-State $State
    }
    foreach($v in $recent){
        $legacyPending=Get-StateFlag $State 'pendingResumes'
        if($legacyPending -and @($legacyPending.PSObject.Properties|Where-Object {$_.Value.ThreadId -eq $v.Id}).Count -gt 0){
            Request-ManualPause $State ('legacy-pending:'+ $v.Id) '旧版续跑仍有未核实记录；本会话暂不重复提交' @{thread=$v.Id}
            continue
        }
        if($v.Outcome -eq 'unknown') {Request-ManualPause $State ('turn:'+ $v.Id+':'+$v.TurnId) '会话异常，需要诊断' @{thread=$v.Id;turn=$v.TurnId;error=$v.Error;engine='lib/engine-v2.ps1';activeAccount=$a.Id;accounts=@($accounts|Select-Object Id,Active,FiveHour,Weekly);switchIncident=(Get-StateFlag $State.switchIncidents ($v.Id+':'+$v.TurnId))};continue}
        if($v.Outcome -notin @('interrupted','unfinished','limit','retryable')){continue}
        if($v.Outcome -ne 'limit' -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$v.At) -lt $Script:Config.ResumeQuietMin*60){continue}
        $n=@($State.handled.PSObject.Properties|Where-Object {$_.Name -like ('desktop:'+$v.Id+':*') -or $_.Name -like ('res:'+$v.Id+':*')}).Count
        if($v.Outcome -ne 'limit' -and $n -ge $Script:Config.ResumeMaxRounds){
            Write-Transition ('cap:'+$v.Id) "对话 $($v.Id.Substring(0,8)) 已达到自动续跑上限，停止重复催促"
            if($v.Outcome -eq 'retryable'){Request-ManualPause $State ('retry-cap:'+ $v.Id) '常见网络错误经过有限续跑仍未恢复' @{thread=$v.Id;error=$v.Error;attempts=$n}}
            continue
        }
        # Preserve prior deployment fingerprints, including the merged handled.json.
        $legacyHandled=Test-LegacyIncidentHandled $State $v
        if(-not $legacyHandled){Send-DesktopContinue $State $v}
    }
    if($a.FiveHour -lt $Script:Config.WarnPercent){
        if($Script:WarnedDryAccount -ne $a.Id){$Script:WarnedDryAccount=$a.Id;Write-Event "当前账号额度不足：$($a.Email)，5 小时剩余 $($a.FiveHour)%" 'WARN'}
    }else{$Script:WarnedDryAccount=$null}
}

function Start-WatchLoop {
    param($State,[int]$MaxRounds=0,[switch]$Once)
    $round=0;$errorStreak=0;$lastError='';$dataFailureSince=$null;$desktopFailureSince=$null
    while($true){
        Wait-ManualPause
        $round++
        try{
            Invoke-WatchRound $State
            if($errorStreak -gt 0){Write-Event '服务或数据已恢复，继续正常看护' 'OK'}
            $errorStreak=0;$lastError=''
            $dataFailureSince=$null;$desktopFailureSince=$null
        }catch{
            if($_.Exception.Data['QuotaManualPause'] -eq $true){
                if($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)){return}
                continue
            }
            $message=$_.Exception.Message
            $policy=Get-RecoveryPolicy $message
            Write-Transition 'loop-error' $(if($policy -eq 'unknown'){"本轮异常，将保存现场并暂停：$message"}else{"等待服务或额度数据恢复：$message"}) $(if($policy -eq 'unknown'){'ERROR'}else{'WARN'})
            if($message -ne $lastError){Write-File $_.ScriptStackTrace 'ERROR'}
            if($message -eq $lastError){$errorStreak++}else{$lastError=$message;$errorStreak=1}
            $grace=Get-StateFlag $State 'desktopReadyAfter'
            $recovering=$grace -and (Get-Date) -lt [datetime]::Parse($grace)
            if($policy -eq 'wait-data' -and -not $dataFailureSince){$dataFailureSince=Get-Date}
            # A missing/closed app can simply be intentional. A responsive catalog
            # with repeated read timeouts is a different incident: bounded diagnosis.
            if($message -match 'Desktop pipe response timeout|桌面列表超时' -and -not $desktopFailureSince){$desktopFailureSince=Get-Date}
            $desktopExpired=$desktopFailureSince -and ((Get-Date)-$desktopFailureSince).TotalMinutes -ge 3
            $dataExpired=$policy -eq 'wait-data' -and $dataFailureSince -and ((Get-Date)-$dataFailureSince).TotalMinutes -ge 5
            if($policy -eq 'unknown' -or (($dataExpired -or $desktopExpired) -and -not $recovering)){
                try{Request-ManualPause $State ('loop:'+ $message) '看护本轮异常' @{error=$message;stack=$_.ScriptStackTrace}}catch{if($_.Exception.Data['QuotaManualPause'] -ne $true){throw}}
            }
        }
        if($Once -or ($MaxRounds -gt 0 -and $round -ge $MaxRounds)){return}
        if(Get-ManualPause){continue}
        $w=Wait-WithStatus -Seconds $Script:Config.PollSeconds -Summary '后台看护运行中；仅显示重要事件'
        if($w -eq 'exit'){Invoke-UserExit;return}
    }
}
