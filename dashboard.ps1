<# Unified desktop UI. Closing this window leaves watcher and schedule alive. #>
[CmdletBinding()]
param([switch]$SmokeTest,[switch]$LibraryOnly,[string]$PreviewPath,[ValidateSet('stopped','running','paused','schedule')][string]$PreviewMode='stopped')
$ErrorActionPreference='Stop'
$Here=$PSScriptRoot
. (Join-Path $Here 'lib\dashboard.ps1')
. (Join-Path $Here 'lib\scheduler.ps1')
if($LibraryOnly){return}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$owned=$false
$mutex=New-Object Threading.Mutex($true,('Local\CodexQuotaDashboard'+$(if($SmokeTest -or $PreviewPath){'-'+$PID}else{''})),[ref]$owned)
if(-not $owned){$mutex.Dispose();exit 0}
$script:uiRun=$null;$script:commandId=$null;$script:commandAt=$null;$script:job=$null;$script:jobProcess=$null
$script:fetch=$null;$script:fetchHandle=$null;$script:fetchAt=[datetime]::MinValue;$script:accounts=@();$script:accountError='读取中'
$script:eventKey='';$script:scheduleKey='';$script:quitting=$false;$script:timer=$null
$color=@{bg=[Drawing.ColorTranslator]::FromHtml('#F2F5FA');nav=[Drawing.ColorTranslator]::FromHtml('#132239');ink=[Drawing.ColorTranslator]::FromHtml('#172B47');muted=[Drawing.ColorTranslator]::FromHtml('#64748B');accent=[Drawing.ColorTranslator]::FromHtml('#087F8C');border=[Drawing.ColorTranslator]::FromHtml('#DAE2ED')}
function Label($Parent,$Text,$X,$Y,$W,$H,$Size=10,$Bold=$false,$Tone='ink'){
    $c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,$H);$c.ForeColor=$color[$Tone];$c.BackColor=[Drawing.Color]::Transparent;$c.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$(if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}));$Parent.Controls.Add($c);return $c
}
function Button($Parent,$Text,$X,$Y,$W=120,$Primary=$false){
    $c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,36);$c.FlatStyle='Flat';$c.FlatAppearance.BorderSize=$(if($Primary){0}else{1});$c.FlatAppearance.BorderColor=$color.border;$c.BackColor=$(if($Primary){$color.accent}else{[Drawing.Color]::White});$c.ForeColor=$(if($Primary){[Drawing.Color]::White}else{$color.ink});$c.Cursor=[Windows.Forms.Cursors]::Hand;$Parent.Controls.Add($c);return $c
}
function Panel($Parent,$X,$Y,$W,$H){$c=New-Object Windows.Forms.Panel;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($W,$H);$c.BackColor=[Drawing.Color]::White;$Parent.Controls.Add($c);return $c}
function Notice($Message,$ErrorFlag=$false){$notice.Text=$Message;$notice.ForeColor=$(if($ErrorFlag){[Drawing.Color]::Firebrick}else{$color.accent})}
function Begin-Command($Action){
    if($script:commandId){return}
    $script:commandId=Send-DashboardCommand $Here $Action;$script:commandAt=Get-Date;Notice '正在处理，请稍候…'
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
    $accountGrid.Rows.Clear()
    foreach($a in $script:accounts){
        $errorText=$a.usage.error;$five=$a.usage.primary.remainingPercent;$week=$a.usage.secondary.remainingPercent
        $state=if($errorText){'读取失败'}elseif($null -eq $five -or $null -eq $week){'额度未知'}elseif($week -le 0){'周额度耗尽'}elseif($five -le 0){'等待五小时恢复'}elseif($a.active){'当前使用'}else{'可用'}
        $reset='--';try{if($a.usage.primary.resetsAt){$reset=([DateTimeOffset]::FromUnixTimeSeconds([long]$a.usage.primary.resetsAt)).ToLocalTime().ToString('MM-dd HH:mm')}}catch{}
        [void]$accountGrid.Rows.Add(@($(if($a.active){'● '+$a.email}else{$a.email}),(Format-DashboardPercent $five $errorText),(Format-DashboardPercent $week $errorText),$reset,$state))
    }
    $active=@($script:accounts|Where-Object active)
    if($active.Count -eq 1){$fiveValue.Text=Format-DashboardPercent $active[0].usage.primary.remainingPercent $active[0].usage.error;$weekValue.Text=Format-DashboardPercent $active[0].usage.secondary.remainingPercent $active[0].usage.error;$currentLabel.Text='当前账号  '+$active[0].email}else{$fiveValue.Text='--';$weekValue.Text='--';$currentLabel.Text='当前账号  未确认'}
    $connection.Text=$(if($script:accountError){'连接：'+$script:accountError}else{'Codex Switch 已连接 · '+$script:accounts.Count+' 个账号'})
}
function Refresh-UI{
    if($PreviewPath){return}
    try{
        $script:uiRun=Get-DashboardRun $Here;$status=Read-DashboardJson (Join-Path $Here 'state\tray-status.json');$pause=Read-DashboardJson (Join-Path $Here 'state\manual-pause.json')
        $paused=$script:uiRun -and $status -and $status.pid -eq $script:uiRun.pid -and $status.paused
        $statusLabel.Text=if(-not $script:uiRun){'尚未启动'}elseif($paused){'已暂停'}else{'看护运行中'}
        $statusLabel.ForeColor=if($paused){[Drawing.Color]::Orange}else{[Drawing.ColorTranslator]::FromHtml('#83E6E1')}
        $elapsedValue.Text=Format-DashboardElapsed $script:uiRun
        $runDetail.Text=if($script:uiRun){$script:uiRun.mode+'  ·  后台 PID '+$script:uiRun.pid}else{'请选择模式开始看护'}
        $pauseButton.Enabled=[bool]$script:uiRun;$pauseButton.Text=if($paused){'恢复看护'}else{'暂停看护'};$stopButton.Enabled=[bool]$script:uiRun
        $startButton.Enabled=(-not $script:uiRun -and -not $script:commandId);$dryButton.Enabled=$startButton.Enabled
        if($pause -and $pause.active){$pauseReason.Text='异常暂停：'+$pause.reason+'。处理后点击恢复。';$reportButton.Visible=$true}else{$pauseReason.Text='关闭窗口仍在托盘运行；双击托盘返回本次运行。';$reportButton.Visible=$false}
        $quota=Read-DashboardJson (Join-Path $Here 'state\quota-status.json')
        if($script:uiRun -and $quota -and $quota.pid -eq $script:uiRun.pid -and $quota.waitingReset){$runDetail.Text+='  ·  等待额度刷新 / 消耗核对'}
        if($script:uiRun){$key=$script:uiRun.id+':';if(Test-Path $script:uiRun.eventFile){$key+=(Get-Item $script:uiRun.eventFile).Length};if($key -ne $script:eventKey){$script:eventKey=$key;$eventsBox.Lines=[string[]](Get-DashboardEvents $Here $script:uiRun);$eventsBox.SelectionStart=$eventsBox.TextLength;$eventsBox.ScrollToCaret()}}
        elseif($script:eventKey){$eventsBox.Text='本次尚未启动看护。';$script:eventKey=''}
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
        $logPath=Join-Path $Here 'logs\scheduler.log';if(Test-Path $logPath){$key=(Get-Item $logPath).Length.ToString();if($key -ne $script:scheduleKey){$script:scheduleKey=$key;$scheduleLog.Lines=[string[]]@(Get-Content $logPath -Tail 120 -Encoding UTF8);$scheduleLog.SelectionStart=$scheduleLog.TextLength;$scheduleLog.ScrollToCaret()}}
        if($script:fetch -and $script:fetchHandle.IsCompleted){
            try{$output=@($script:fetch.EndInvoke($script:fetchHandle));$data=($output -join '')|ConvertFrom-Json;if($data.ok){$script:accounts=@($data.accounts);$script:accountError=''}else{$script:accountError='暂不可用；显示上次额度'}}catch{$script:accountError='读取失败；显示上次额度'}finally{$script:fetch.Dispose();$script:fetch=$null}
            Render-Accounts
        }
        Start-AccountRead
    }catch{Notice ('界面刷新失败：'+$_.Exception.Message) $true}
}
$form=New-Object Windows.Forms.Form
$form.Text='Codex 额度看护';$form.StartPosition='CenterScreen';$form.ClientSize=New-Object Drawing.Size(1050,750);$form.MinimumSize=New-Object Drawing.Size(1066,789);$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$form.AutoScaleMode='Dpi';$form.BackColor=$color.bg
$iconPath=Join-Path $Here 'assets\codex-quota.ico';if(Test-Path $iconPath){$form.Icon=New-Object Drawing.Icon($iconPath)}
$header=Panel $form 0 0 1050 85;$header.BackColor=$color.nav;$header.Anchor='Top,Left,Right'
$brand=Label $header 'Codex 额度看护' 24 16 600 33 20 $true;$brand.ForeColor=[Drawing.Color]::White
$tagline=Label $header '账号看护 · 自动续跑 · 额度定时' 26 54 650 23 10;$tagline.ForeColor=[Drawing.ColorTranslator]::FromHtml('#A9BDD3')
$statusLabel=Label $header '尚未启动' 817 28 210 31 13 $true 'accent';$statusLabel.TextAlign='MiddleRight';$statusLabel.ForeColor=[Drawing.ColorTranslator]::FromHtml('#83E6E1')
$tabs=New-Object Windows.Forms.TabControl;$tabs.Location=New-Object Drawing.Point(20,100);$tabs.Size=New-Object Drawing.Size(1010,588);$tabs.Anchor='Top,Bottom,Left,Right';$tabs.Padding=New-Object Drawing.Point(25,8);$form.Controls.Add($tabs)
$overview=New-Object Windows.Forms.TabPage('看护');$overview.BackColor=$color.bg;$schedulePage=New-Object Windows.Forms.TabPage('额度定时');$schedulePage.BackColor=$color.bg;$tabs.TabPages.AddRange(@($overview,$schedulePage))
$card1=Panel $overview 12 15 330 94;$card2=Panel $overview 354 15 309 94;$card3=Panel $overview 675 15 309 94
$null=Label $card1 '已监视运行' 16 10 210 24 10 $false 'muted';$elapsedValue=Label $card1 '尚未启动' 16 36 298 40 22 $true
$null=Label $card2 '当前账号 · 五小时剩余' 16 10 275 24 10 $false 'muted';$fiveValue=Label $card2 '--' 16 35 270 41 25 $true 'accent'
$null=Label $card3 '当前账号 · 周剩余' 16 10 275 24 10 $false 'muted';$weekValue=Label $card3 '--' 16 35 270 41 25 $true 'accent'
$startButton=Button $overview '2  正常模式' 12 124 144 $true;$dryButton=Button $overview '1  演习模式' 168 124 134;$pauseButton=Button $overview '暂停看护' 314 124 126;$stopButton=Button $overview '停止看护' 452 124 126
$runDetail=Label $overview '请选择模式开始看护' 594 132 389 23 10 $false 'muted'
$pauseReason=Label $overview '关闭窗口仍在托盘运行；双击托盘返回本次运行。' 12 169 798 27 10 $false 'muted';$reportButton=Button $overview '查看异常报告' 825 164 156;$reportButton.Visible=$false
$currentLabel=Label $overview '当前账号  未确认' 12 202 580 24 10 $true
$accountGrid=New-Object Windows.Forms.DataGridView;$accountGrid.Location=New-Object Drawing.Point(12,234);$accountGrid.Size=New-Object Drawing.Size(972,161);$accountGrid.BackgroundColor=[Drawing.Color]::White;$accountGrid.BorderStyle='None';$accountGrid.ReadOnly=$true;$accountGrid.AllowUserToAddRows=$false;$accountGrid.AllowUserToDeleteRows=$false;$accountGrid.AllowUserToResizeRows=$false;$accountGrid.RowHeadersVisible=$false;$accountGrid.EnableHeadersVisualStyles=$false;$accountGrid.AutoSizeColumnsMode='Fill';$accountGrid.SelectionMode='FullRowSelect';$accountGrid.MultiSelect=$false;$accountGrid.ScrollBars='Vertical';$accountGrid.GridColor=$color.border;$accountGrid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#E6EDF5');$accountGrid.ColumnHeadersDefaultCellStyle.ForeColor=$color.ink;$accountGrid.ColumnHeadersHeight=29;$accountGrid.RowTemplate.Height=25;$accountGrid.DefaultCellStyle.SelectionBackColor=[Drawing.ColorTranslator]::FromHtml('#E0F2F3');$accountGrid.DefaultCellStyle.SelectionForeColor=$color.ink;$accountGrid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#F8FAFC')
foreach($title in @('账号','五小时剩余','周剩余','五小时恢复时间','状态')){[void]$accountGrid.Columns.Add($title,$title)};$accountGrid.Columns[0].FillWeight=240;$accountGrid.Columns[3].FillWeight=150;$overview.Controls.Add($accountGrid)
$null=Label $overview '本次运行的重要事件' 12 404 640 25 11 $true
$eventsBox=New-Object Windows.Forms.TextBox;$eventsBox.Multiline=$true;$eventsBox.ScrollBars='Vertical';$eventsBox.Location=New-Object Drawing.Point(12,434);$eventsBox.Size=New-Object Drawing.Size(972,107);$eventsBox.ReadOnly=$true;$eventsBox.BorderStyle='None';$eventsBox.BackColor=[Drawing.Color]::White;$eventsBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$eventsBox.Text='本次尚未启动看护。';$eventsBox.Anchor='Top,Bottom,Left,Right';$overview.Controls.Add($eventsBox)
$null=Label $schedulePage '每天执行时间' 20 17 600 29 16 $true
$scheduleSummary=Label $schedulePage '由 Windows 定时任务执行，关闭窗口仍然有效。' 20 52 936 34 10 $false 'muted'
$settingsCard=Panel $schedulePage 20 93 947 245
$null=Label $settingsCard 'Codex Switch 监听端口' 18 18 238 24 10
$portBox=New-Object Windows.Forms.NumericUpDown;$portBox.Location=New-Object Drawing.Point(268,15);$portBox.Size=New-Object Drawing.Size(120,29);$portBox.Minimum=1;$portBox.Maximum=65535;$config=Get-ScheduleConfig;$portBox.Value=$config.port;$settingsCard.Controls.Add($portBox)
$testButton=Button $settingsCard '测试连接' 415 11 140
$timesList=New-Object Windows.Forms.ListBox;$timesList.Location=New-Object Drawing.Point(18,64);$timesList.Size=New-Object Drawing.Size(370,148);$timesList.Font=New-Object Drawing.Font('Microsoft YaHei UI',14);$timesList.SelectionMode='MultiExtended';$timesList.BorderStyle='FixedSingle';$settingsCard.Controls.Add($timesList)
foreach($time in @($config.times)){[void]$timesList.Items.Add([string]$time)}
$scheduleSummary.Text=$(if($config.enabled -and @($config.times).Count){'已启用 · 每天 '+(@($config.times)-join '、')+' · 关闭窗口仍然有效'}else{'定时未启用 · 添加时间后保存并启用'})
$timePicker=New-Object Windows.Forms.DateTimePicker;$timePicker.Location=New-Object Drawing.Point(415,68);$timePicker.Size=New-Object Drawing.Size(140,29);$timePicker.Format='Custom';$timePicker.CustomFormat='HH:mm';$timePicker.ShowUpDown=$true;$settingsCard.Controls.Add($timePicker)
$addTime=Button $settingsCard '添加时间' 571 64 148;$removeTime=Button $settingsCard '移除选中' 415 110 140;$clearTime=Button $settingsCard '清空列表' 571 110 148
$saveButton=Button $settingsCard '保存并启用' 415 167 160 $true;$disableButton=Button $settingsCard '停用定时' 591 167 128
$consumeButton=Button $schedulePage '立即消耗一次' 20 352 173 $true;$null=Label $schedulePage '对可用账号执行一次；没有额度的跳过。与自动消耗协调，未知结果不重试。' 212 357 752 41 10 $false 'muted'
$null=Label $schedulePage '定时与手动执行日志' 20 403 930 26 11 $true
$scheduleLog=New-Object Windows.Forms.TextBox;$scheduleLog.Multiline=$true;$scheduleLog.ScrollBars='Vertical';$scheduleLog.Location=New-Object Drawing.Point(20,435);$scheduleLog.Size=New-Object Drawing.Size(947,106);$scheduleLog.ReadOnly=$true;$scheduleLog.BorderStyle='None';$scheduleLog.BackColor=[Drawing.Color]::White;$scheduleLog.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$schedulePage.Controls.Add($scheduleLog)
$connection=Label $form 'Codex Switch 读取中…' 24 706 600 22 9 $false 'muted';$connection.Anchor='Bottom,Left'
$notice=Label $form '' 24 684 850 24 9 $false 'accent';$notice.Anchor='Bottom,Left';$hideButton=Button $form '收回托盘' 890 697 138;$hideButton.Anchor='Bottom,Right'
$startButton.Add_Click({Begin-Command 'start-live'});$dryButton.Add_Click({Begin-Command 'start-dry'})
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
$form.Add_Shown({if(-not $PreviewPath -and -not $SmokeTest){Write-ScheduleJson (Join-Path $Here 'state\dashboard-window.json') @{pid=$PID;handle=$form.Handle.ToInt64();visible=$form.Visible;at=(Get-Date).ToString('o')}}})
try{
    if($PreviewPath){
        $script:accounts=@(1..5|ForEach-Object {[pscustomobject]@{email="account$_@example.com";active=($_ -eq 1);usage=@{error=$null;primary=@{remainingPercent=100-$_*12;resetsAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+18000};secondary=@{remainingPercent=100-$_*8}}}});$script:accountError='';Render-Accounts
        $statusLabel.Text=$(if($PreviewMode -eq 'paused'){'异常暂停'}elseif($PreviewMode -eq 'stopped'){'尚未启动'}else{'看护运行中'});$elapsedValue.Text='3小时20分';$runDetail.Text='正常模式 · 后台 PID 12345'
        $eventsBox.Text="10-12 11:30:00 [INFO] 看护已启动`r`n10-12 11:35:21 [OK] 已确认切换到周额度最高的账号`r`n10-12 11:35:33 [OK] 两条中断对话已恢复运行"
        $scheduleSummary.Text='已启用 · 每天 10:35 · 关闭窗口仍然有效';$scheduleLog.Text="10-12 10:35:00 [INFO] 定时消耗开始`r`n10-12 10:35:12 [INFO] 成功 4 个，跳过 1 个，未确认 0 个"
        if($PreviewMode -eq 'schedule'){$tabs.SelectedTab=$schedulePage}
        if($PreviewMode -eq 'paused'){$pauseReason.Text='异常暂停：会话错误超出现有规则。处理后点击恢复。';$reportButton.Visible=$true}
        $form.Show();[Windows.Forms.Application]::DoEvents();$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height);$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();$form.Close()
    }else{
        Refresh-UI;$script:timer=New-Object Windows.Forms.Timer;$script:timer.Interval=1000;$script:timer.Add_Tick({if($SmokeTest){$form.Close()}else{Refresh-UI}});$script:timer.Start();[void]$form.ShowDialog()
    }
}catch{Write-SchedulerEvent ('合并界面异常：'+$_.Exception.ToString()) 'ERROR';throw}
finally{if($script:timer){$script:timer.Stop();$script:timer.Dispose()};if($script:fetch){$script:fetch.Stop();$script:fetch.Dispose()};$form.Dispose();if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
