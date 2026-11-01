<# Unified desktop UI. Closing this window leaves watcher and schedule alive. #>
[CmdletBinding()]
param([switch]$SmokeTest,[switch]$LibraryOnly,[string]$PreviewPath,[ValidateSet('stopped','running','paused','schedule')][string]$PreviewMode='stopped',[int]$PreviewWidth=0,[int]$PreviewHeight=0)
$ErrorActionPreference='Stop'
$Here=$PSScriptRoot
. (Join-Path $Here 'lib\dashboard.ps1')
. (Join-Path $Here 'lib\account-quota.ps1')
. (Join-Path $Here 'lib\scheduler.ps1')
if($LibraryOnly){return}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $Here 'lib\log-view.ps1')
[Windows.Forms.Application]::EnableVisualStyles()
$owned=$false
$mutex=New-Object Threading.Mutex($true,('Local\CodexQuotaDashboard'+$(if($SmokeTest -or $PreviewPath){'-'+$PID}else{''})),[ref]$owned)
if(-not $owned){$mutex.Dispose();exit 0}
$script:uiRun=$null;$script:commandId=$null;$script:commandAt=$null;$script:job=$null;$script:jobProcess=$null
$script:fetch=$null;$script:fetchHandle=$null;$script:fetchAt=[datetime]::MinValue;$script:accounts=@();$script:accountError='读取中'
$script:eventKey='';$script:scheduleKey='';$script:quitting=$false;$script:timer=$null
$script:displayReservePolicy=$null;$script:lastActiveRunId=$null
$color=@{bg=[Drawing.ColorTranslator]::FromHtml('#F3F6F5');ink=[Drawing.ColorTranslator]::FromHtml('#243635');muted=[Drawing.ColorTranslator]::FromHtml('#64756E');accent=[Drawing.ColorTranslator]::FromHtml('#246557');soft=[Drawing.ColorTranslator]::FromHtml('#E4EFE9');warning=[Drawing.ColorTranslator]::FromHtml('#A36A16');border=[Drawing.ColorTranslator]::FromHtml('#E2E8E4')}
function Label($Parent,$Text,$X,$Y,$W,$H,$Size=10,$Bold=$false,$Tone='ink'){
    $c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,$H);$c.ForeColor=$color[$Tone];$c.BackColor=[Drawing.Color]::Transparent;$c.AutoEllipsis=$true;$c.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$(if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}));$Parent.Controls.Add($c);return $c
}
function Button($Parent,$Text,$X,$Y,$W=120,$Primary=$false){
    $c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,36);$c.FlatStyle='Flat';$c.FlatAppearance.BorderSize=$(if($Primary){0}else{1});$c.FlatAppearance.BorderColor=$color.border;$c.BackColor=$(if($Primary){$color.accent}else{[Drawing.Color]::White});$c.ForeColor=$(if($Primary){[Drawing.Color]::White}else{$color.ink});$c.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$c.FlatAppearance.MouseOverBackColor=$(if($Primary){[Drawing.ColorTranslator]::FromHtml('#1D5146')}else{$color.soft});$c.Cursor=[Windows.Forms.Cursors]::Hand;$Parent.Controls.Add($c);return $c
}
function Panel($Parent,$X,$Y,$W,$H){$c=New-Object Windows.Forms.Panel;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,$H);$c.BackColor=[Drawing.Color]::White;$Parent.Controls.Add($c);return $c}
function Notice($Message,$ErrorFlag=$false){$notice.Text=$Message;$notice.ForeColor=$(if($ErrorFlag){[Drawing.Color]::Firebrick}else{$color.accent})}
function Begin-Command($Action){
    if($script:commandId){return}
    $options=@{}
    if($Action -eq 'start-live'){$options.reserveCount=if($reserveToggle.Checked){[int]$reserveNumber.Value}else{0}}
    $script:commandId=Send-DashboardCommand $Here $Action -Options $options;$script:commandAt=Get-Date;Notice '正在处理，请稍候…'
}
function Begin-ScheduleAction($Action){
    if($script:job){return}
    $request=@{action=$Action;port=[int]$portBox.Value;times=@($timesList.Items|ForEach-Object {[string]$_});enabled=$true}
    $path=Join-Path $Here ('state\scheduler\requests\'+[guid]::NewGuid().ToString('N')+'.json');Write-ScheduleJson $path $request
    $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RequestFile "{1}"' -f (Join-Path $Here 'scheduler.ps1'),$path
    $script:jobProcess=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:job=$path;Notice '操作已交给后台，窗口可以关闭。'
}
function Start-AccountRead{
    if($script:fetch -or $PreviewPath -or $SmokeTest -or (Get-Date)-lt $script:fetchAt){return}
    $script:fetchAt=(Get-Date).AddSeconds(5)
    $config=Get-ScheduleConfig;$port=[int]$config.port
    $script:fetch=[Management.Automation.PowerShell]::Create()
    [void]$script:fetch.AddScript({param($Port)
        try{
            $httpOptions=@{}
            if((Get-Command Invoke-RestMethod).Parameters.ContainsKey('NoProxy')){$httpOptions.NoProxy=$true}
            $r=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/__codex_switch__/api/invoke" -Method Post -ContentType application/json -Body '{"command":"list_accounts","args":{}}' -TimeoutSec 8 @httpOptions
            if(-not $r.ok){throw $r.error}
            @{ok=$true;accounts=@($r.result|Select-Object id,email,active,directSwitchCompatible,usage)}|ConvertTo-Json -Depth 8 -Compress
        }catch{@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress}
    }).AddArgument($port)
    $script:fetchHandle=$script:fetch.BeginInvoke()
}
function Render-Accounts{
    $reserveTotal=@($script:accounts|Where-Object {(ConvertFrom-AccountUsage $_.usage).FiveHourLimitAbsent}).Count
    $reserveNumber.Maximum=[Math]::Max([Math]::Max(1,$reserveTotal),[int](Get-QuotaProperty $script:uiRun 'reserveRequestedCount'))
    $reserveTotalLabel.Text='/ '+$reserveTotal+' 个'
    $reserveToggle.Enabled=(-not $script:uiRun -and -not $script:commandId -and $reserveTotal -gt 0 -and -not $script:accountError)
    $reserveNumber.Enabled=($reserveToggle.Enabled -and $reserveToggle.Checked)
    $accountsHeading.Text='账号列表  '+$script:accounts.Count
    $sortHint.Text='普通账号 '+($script:accounts.Count-$reserveTotal)+' 个    备选账号 '+$reserveTotal+' 个'
    $sortColumn=$accountGrid.SortedColumn
    $sortOrder=$accountGrid.SortOrder
    $accountGrid.Rows.Clear()
    $displayAccounts=@($script:accounts|Where-Object active)+@($script:accounts|Where-Object {-not $_.active})
    foreach($a in $displayAccounts){
        $q=ConvertFrom-AccountUsage $a.usage;$errorText=$q.UsageError;$week=$q.Weekly
        $reserveState=if(-not $script:uiRun){'备选账号'}elseif($script:displayReservePolicy -and $a.id -in @($script:displayReservePolicy.selectedIds)){'本次备选'}else{'备选未启用'}
        $state=if($q.FiveHourLimitAbsent -and $reserveState -eq '备选未启用'){$reserveState}elseif($errorText){'读取失败'}elseif(-not (Test-AccountQuotaKnown $q)){'额度未知'}elseif($week -le 0){'周额度耗尽'}elseif(-not (Test-AccountQuotaAvailable $q)){'等待五小时恢复'}elseif($a.active){'当前使用'}elseif($q.FiveHourLimitAbsent){$reserveState}else{'可用'}
        $reset='--';try{if($q.FiveHourReset){$reset=([DateTimeOffset]::FromUnixTimeSeconds([long]$q.FiveHourReset)).ToLocalTime().ToString('MM-dd HH:mm')}}catch{}
        $rowIndex=$accountGrid.Rows.Add(@($(if($a.active){'● '+$a.email}else{$a.email}),(Format-AccountFiveHour $q),(Format-DashboardPercent $week $errorText),$reset,$state))
        $accountGrid.Rows[$rowIndex].Tag=[pscustomobject]@{
            id=$a.id;active=[bool]$a.active
            reserve=($q.FiveHourLimitAbsent -or ($script:displayReservePolicy -and $a.id -in @(Get-QuotaProperty $script:displayReservePolicy 'knownReserveIds')))
            weekly=$(if($errorText){$null}else{$week})
        }
        $row=$accountGrid.Rows[$rowIndex]
        if($a.active){
            $row.DefaultCellStyle.BackColor=$color.soft
            $row.DefaultCellStyle.SelectionBackColor=[Drawing.ColorTranslator]::FromHtml('#CCE2D5')
            $row.Cells[0].Style.Font=$script:ActiveAccountFont
            $row.Cells[4].Style.ForeColor=$color.accent
        }elseif($row.Tag.reserve){$row.DefaultCellStyle.ForeColor=$color.muted}
        if(-not $q.FiveHourLimitAbsent -and $null -ne $q.FiveHour -and $q.FiveHour -le 15){$row.Cells[1].Style.ForeColor=$color.warning}
        if($null -ne $q.Weekly -and $q.Weekly -le 15){$row.Cells[2].Style.ForeColor=$color.warning}
    }
    if($sortColumn -and $sortOrder -ne [Windows.Forms.SortOrder]::None){
        $direction=if($sortOrder -eq [Windows.Forms.SortOrder]::Descending){[ComponentModel.ListSortDirection]::Descending}else{[ComponentModel.ListSortDirection]::Ascending}
        $accountGrid.Sort($sortColumn,$direction)
    }else{
        $accountGrid.Sort($accountGrid.Columns[2],[ComponentModel.ListSortDirection]::Descending)
    }
    $active=@($script:accounts|Where-Object active)
    if($active.Count -eq 1){$q=ConvertFrom-AccountUsage $active[0].usage;$fiveValue.Text=Format-AccountFiveHour $q;$weekValue.Text=Format-DashboardPercent $q.Weekly $q.UsageError;$currentLabel.Text=$active[0].email}else{$fiveValue.Text='--';$weekValue.Text='--';$currentLabel.Text='当前账号未确认'}
    Update-QuotaMeters
    $connection.Text=$(if($script:accountError){'连接：'+$script:accountError}else{'Codex Switch 已连接 · '+$script:accounts.Count+' 个账号'})
}
function Refresh-UI{
    if($PreviewPath){return}
    try{
        $script:uiRun=Get-DashboardRun $Here;$status=Read-DashboardJson (Join-Path $Here 'state\tray-status.json');$pause=Read-DashboardJson (Join-Path $Here 'state\manual-pause.json')
        $paused=$script:uiRun -and $status -and $status.pid -eq $script:uiRun.pid -and $status.paused
        $statusLabel.Text=if(-not $script:uiRun){'尚未启动'}elseif($paused){'已暂停'}else{'看护运行中'}
        $statusLabel.ForeColor=if($paused){$color.warning}else{$color.accent}
        $statusLabel.BackColor=if($paused){[Drawing.ColorTranslator]::FromHtml('#FAEED8')}else{$color.soft}
        $elapsedValue.Text=if($script:uiRun){'已运行 '+(Format-DashboardElapsed $script:uiRun)}else{'等待启动'}
        $runDetail.Text=if($script:uiRun){'普通账号优先，备选'+$(if([int](Get-QuotaProperty $script:uiRun 'reserveRequestedCount') -gt 0){'已启用 '+$script:uiRun.reserveRequestedCount+' 个'}else{'未启用'})}else{'启动后自动检查额度与任务状态'}
        $pauseButton.Enabled=[bool]$script:uiRun;$pauseButton.Text=if($paused){'恢复看护'}else{'暂停看护'};$stopButton.Enabled=[bool]$script:uiRun
        $startButton.Enabled=(-not $script:uiRun -and -not $script:commandId)
        $startButton.BackColor=if($startButton.Enabled){$color.accent}else{$color.border}
        if($script:uiRun){
            $requested=[int](Get-QuotaProperty $script:uiRun 'reserveRequestedCount')
            $reserveNumber.Maximum=[Math]::Max([int]$reserveNumber.Maximum,[Math]::Max(1,$requested))
            $reserveToggle.Checked=$requested -gt 0
            $reserveNumber.Value=[Math]::Max(1,$requested)
            $script:lastActiveRunId=$script:uiRun.id
        }elseif($script:lastActiveRunId){$reserveToggle.Checked=$false;$reserveNumber.Value=1;$script:lastActiveRunId=$null}
        $reserveToggle.Enabled=(-not $script:uiRun -and -not $script:commandId -and @($script:accounts).Count -gt 0 -and -not $script:accountError -and @($script:accounts|Where-Object {(ConvertFrom-AccountUsage $_.usage).FiveHourLimitAbsent}).Count -gt 0)
        $reserveNumber.Enabled=$reserveToggle.Enabled -and $reserveToggle.Checked
        if($pause -and $pause.active){$pauseReason.Text='异常暂停：'+$pause.reason+'。处理后点击恢复。';$pauseReason.ForeColor=$color.warning;$reportButton.Visible=$true}else{$pauseReason.Text='关闭窗口后继续在托盘运行。';$pauseReason.ForeColor=$color.muted;$reportButton.Visible=$false}
        $quota=Read-DashboardJson (Join-Path $Here 'state\quota-status.json')
        $script:displayReservePolicy=if($script:uiRun -and $quota -and $quota.pid -eq $script:uiRun.pid){Get-QuotaProperty $quota 'reservePolicy'}else{$null}
        if($script:uiRun -and -not $paused -and $quota -and $quota.pid -eq $script:uiRun.pid -and $quota.desktopHealth.mode -in @('degraded','unavailable')){
            $statusLabel.Text='等待桌面连接';$statusLabel.ForeColor=$color.warning
            $runDetail.Text='正在恢复桌面连接，连接后继续看护'
        }
        if($script:uiRun -and $quota -and $quota.pid -eq $script:uiRun.pid -and $quota.waitingReset){$runDetail.Text+='  ·  等待额度刷新 / 消耗核对'}
        if($script:uiRun){$key=$script:uiRun.id+':';if(Test-Path $script:uiRun.eventFile){$key+=(Get-Item $script:uiRun.eventFile).Length};if($key -ne $script:eventKey){$script:eventKey=$key;Set-DashboardLogText $eventsBox ([string[]](Get-DashboardEvents $Here $script:uiRun)) $followEvents.Checked}}
        elseif($script:eventKey){$eventsBox.Text='启动看护后，这里会显示切号、恢复任务等重要事件。';$script:eventKey=''}
        if($script:commandId){
            $reply=Read-DashboardJson (Join-Path $Here 'state\tray-host-result.json')
            if($reply -and $reply.id -eq $script:commandId){Notice $(if($reply.success){'操作完成'}else{$reply.error}) (-not $reply.success);$script:commandId=$null}
            elseif(((Get-Date)-$script:commandAt).TotalSeconds -gt 15){Notice '操作尚未确认，请检查托盘日志；不会自动重复提交。' $true;$script:commandId=$null}
        }
        if($script:job){
            $result=Read-DashboardJson ($script:job+'.result.json')
            if($result){Notice $result.message (-not $result.ok);$script:job=$null;$script:scheduleKey='';$cfg=Get-ScheduleConfig;$scheduleSummary.Text=$(if($cfg.enabled -and @($cfg.times).Count){'已启用 · 每天 '+(@($cfg.times)-join '、')+' · 关闭窗口仍然有效'}else{'定时未启用 · 时间设置保留'})}
            else{$script:jobProcess.Refresh();if($script:jobProcess.HasExited){Notice '后台操作结束但结果未确认，请查看定时日志。' $true;$script:job=$null}}
        }
        $saveButton.Enabled=(-not $script:job);$testButton.Enabled=$saveButton.Enabled;$consumeButton.Enabled=$saveButton.Enabled;$disableButton.Enabled=$saveButton.Enabled
        $logPath=Join-Path $Here 'logs\scheduler.log';if(Test-Path $logPath){$key=(Get-Item $logPath).Length.ToString();if($key -ne $script:scheduleKey){$script:scheduleKey=$key;Set-DashboardLogText $scheduleLog ([string[]]@(Get-Content $logPath -Tail 120 -Encoding UTF8)) $followSchedule.Checked}}
        if($script:fetch -and $script:fetchHandle.IsCompleted){
            try{$output=@($script:fetch.EndInvoke($script:fetchHandle));$data=($output -join '')|ConvertFrom-Json;if($data.ok){$script:accounts=@($data.accounts);$script:accountError=''}else{$script:accountError='暂不可用；显示上次额度'}}catch{$script:accountError='读取失败；显示上次额度'}finally{$script:fetch.Dispose();$script:fetch=$null}
            Render-Accounts
        }
        Start-AccountRead
    }catch{Notice ('界面刷新失败：'+$_.Exception.Message) $true}
}
. (Join-Path $Here 'lib\dashboard-layout.ps1')
$startButton.Add_Click({Begin-Command 'start-live'})
$pauseButton.Add_Click({$s=Read-DashboardJson (Join-Path $Here 'state\tray-status.json');$action=if($s -and $s.paused){'resume'}else{'pause'};$null=Send-DashboardCommand $Here $action -Watcher;Notice '已提交暂停/恢复请求'})
$stopButton.Add_Click({Begin-Command 'stop'})
$reportButton.Add_Click({$p=Read-DashboardJson (Join-Path $Here 'state\manual-pause.json');if($p -and (Test-Path $p.reportPath)){Start-Process notepad.exe -ArgumentList ('"'+$p.reportPath+'"')}})
$hideButton.Add_Click({$form.Close()})
$addTime.Add_Click({$times=@($timesList.Items|ForEach-Object {[string]$_})+@($timePicker.Value.ToString('HH:mm'));$timesList.Items.Clear();foreach($time in @($times|Sort-Object -Unique)){[void]$timesList.Items.Add($time)}})
$removeTime.Add_Click({foreach($time in @($timesList.SelectedItems)){$timesList.Items.Remove($time)}});$clearTime.Add_Click({$timesList.Items.Clear()})
$saveButton.Add_Click({try{Begin-ScheduleAction 'save'}catch{Notice $_.Exception.Message $true}})
$disableButton.Add_Click({try{Begin-ScheduleAction 'disable'}catch{Notice $_.Exception.Message $true}})
$testButton.Add_Click({try{Begin-ScheduleAction 'test'}catch{Notice $_.Exception.Message $true}})
$consumeButton.Add_Click({if([Windows.Forms.MessageBox]::Show($form,'立即对可用账号消耗一次额度？这会消耗少量 Codex 额度。','确认执行','YesNo','Question') -eq 'Yes'){try{Begin-ScheduleAction 'consume'}catch{Notice $_.Exception.Message $true}}})
$form.Add_Shown({Resize-DashboardLayout;if($followEvents.Checked){$eventsBox.SelectionStart=$eventsBox.TextLength;$eventsBox.ScrollToCaret()};if(-not $PreviewPath -and -not $SmokeTest){Write-ScheduleJson (Join-Path $Here 'state\dashboard-window.json') @{pid=$PID;handle=$form.Handle.ToInt64();visible=$form.Visible;at=(Get-Date).ToString('o')}}})
try{
    if($PreviewPath){
        if($PreviewWidth -gt 0 -and $PreviewHeight -gt 0){$form.ClientSize=New-Object Drawing.Size($PreviewWidth,$PreviewHeight)}
        $form.Show();[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
        $script:accounts=@(1..6|ForEach-Object {[pscustomobject]@{id="a$_";email="account$_@example.com";active=($_ -eq 1);usage=@{error=$null;primary=@{remainingPercent=100-$_*15;windowMinutes=300;resetsAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000};secondary=@{remainingPercent=100-$_*8;windowMinutes=10080}}}})
        $script:accounts+=@(1..3|ForEach-Object {[pscustomobject]@{id="r$_";email="reserve$_@example.com";active=$false;usage=@{error=$null;primary=@{remainingPercent=20+$_*25;windowMinutes=10080};secondary=$null}}})
        if($PreviewMode -ne 'stopped'){$script:uiRun=[pscustomobject]@{reserveRequestedCount=0};$script:displayReservePolicy=[pscustomobject]@{selectedIds=@();knownReserveIds=@('r1','r2','r3')};$startButton.Enabled=$false;$startButton.BackColor=$color.border}
        $script:accountError='';Render-Accounts
        $statusLabel.Text=$(if($PreviewMode -eq 'paused'){'异常暂停'}elseif($PreviewMode -eq 'stopped'){'尚未启动'}else{'看护运行中'});$elapsedValue.Text='已运行 3小时20分';$runDetail.Text='普通账号优先，备选未启用'
        if($PreviewMode -eq 'stopped'){$elapsedValue.Text='尚未启动';$runDetail.Text='设置备选数量后启动看护';$pauseButton.Enabled=$false;$stopButton.Enabled=$false}
        $eventsBox.Text="10-12 11:30:00 [INFO] 看护已启动`r`n10-12 11:35:21 [OK] 已确认切换到周额度最高的账号`r`n10-12 11:35:33 [OK] 两条中断对话已恢复运行"
        $scheduleLog.Text="11-01 09:07:00 [INFO] 定时消耗开始`r`n11-01 09:07:12 [INFO] 成功 6 个，跳过 3 个，未确认 0 个"
        if($PreviewMode -eq 'schedule'){$tabs.SelectedTab=$schedulePage}
        if($PreviewMode -eq 'paused'){$pauseReason.Text='异常暂停：会话错误超出现有规则。处理后点击恢复。';$pauseReason.ForeColor=$color.warning;$statusLabel.ForeColor=$color.warning;$statusLabel.BackColor=[Drawing.ColorTranslator]::FromHtml('#FAEED8');$pauseButton.Text='恢复看护';$reportButton.Visible=$true}
        $form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();$form.Close()
    }else{
        Refresh-UI;$script:timer=New-Object Windows.Forms.Timer;$script:timer.Interval=1000;$script:timer.Add_Tick({if($SmokeTest){$form.Close()}else{Refresh-UI}});$script:timer.Start();[void]$form.ShowDialog()
    }
}catch{Write-SchedulerEvent ('合并界面异常：'+$_.Exception.ToString()) 'ERROR';throw}
finally{if($script:timer){$script:timer.Stop();$script:timer.Dispose()};if($script:fetch){$script:fetch.Stop();$script:fetch.Dispose()};$form.Dispose();$reserveTip.Dispose();$script:ActiveAccountFont.Dispose();if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
