# Native desktop layout. All coordinates are logical pixels; resizing leaves
# room for the account roster first, then expands the event history.
$form=New-Object Windows.Forms.Form
$form.Text='Codex 额度看护';$form.StartPosition='CenterScreen'
$form.ClientSize=New-Object Drawing.Size(1120,900);$form.MinimumSize=New-Object Drawing.Size(1056,819)
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$form.AutoScaleDimensions=New-Object Drawing.SizeF(96,96);$form.AutoScaleMode='Dpi';$form.BackColor=$color.bg
$iconPath=Join-Path $Here 'assets\codex-quota.ico';if(Test-Path $iconPath){$form.Icon=New-Object Drawing.Icon($iconPath)}
$header=Panel $form 0 0 1120 86
$brand=Label $header 'Codex 额度看护' 28 17 540 32 18 $true
$tagline=Label $header '账号轮转与任务续跑' 29 52 540 23 9 $false 'muted'
$statusLabel=Label $header '尚未启动' 916 18 176 29 11 $true 'accent';$statusLabel.TextAlign='MiddleCenter';$statusLabel.BackColor=$color.soft
$elapsedValue=Label $header '等待启动' 850 53 242 22 9 $false 'muted';$elapsedValue.TextAlign='MiddleRight'
$tabs=New-Object Windows.Forms.TabControl;$tabs.SetBounds(24,99,1072,698);$tabs.Padding=New-Object Drawing.Point(25,9);$tabs.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.Controls.Add($tabs)
$overview=New-Object Windows.Forms.TabPage('账号看护');$overview.BackColor=$color.bg
$schedulePage=New-Object Windows.Forms.TabPage('额度定时');$schedulePage.BackColor=$color.bg
$tabs.TabPages.AddRange(@($overview,$schedulePage))

$summaryPanel=Panel $overview 12 14 1040 112
$summaryAccent=Panel $summaryPanel 0 0 4 112;$summaryAccent.BackColor=$color.accent
$currentCaption=Label $summaryPanel '当前账号' 20 13 410 23 9 $false 'muted'
$currentLabel=Label $summaryPanel '正在读取账号…' 20 38 560 31 16 $true;$currentLabel.AutoEllipsis=$true
$runDetail=Label $summaryPanel '启动后自动检查额度与任务状态' 20 78 560 22 9 $false 'muted'
$fiveCaption=Label $summaryPanel '五小时剩余' 620 14 160 23 9 $false 'muted'
$fiveValue=Label $summaryPanel '--' 620 37 160 38 24 $true 'accent';$fiveValue.Font=New-Object Drawing.Font('Segoe UI',24,[Drawing.FontStyle]::Bold)
$fiveTrack=Panel $summaryPanel 620 89 160 5;$fiveTrack.BackColor=$color.soft
$fiveFill=Panel $fiveTrack 0 0 0 5;$fiveFill.BackColor=$color.accent
$weekCaption=Label $summaryPanel '周剩余' 830 14 170 23 9 $false 'muted'
$weekValue=Label $summaryPanel '--' 830 37 170 38 24 $true 'accent';$weekValue.Font=New-Object Drawing.Font('Segoe UI',24,[Drawing.FontStyle]::Bold)
$weekTrack=Panel $summaryPanel 830 89 170 5;$weekTrack.BackColor=$color.soft
$weekFill=Panel $weekTrack 0 0 0 5;$weekFill.BackColor=$color.accent

$startButton=Button $overview '启动看护' 12 140 124 $true
$pauseButton=Button $overview '暂停看护' 148 140 104
$stopButton=Button $overview '停止看护' 264 140 104
$reservePanel=Panel $overview 392 140 250 36
$reserveToggle=New-Object Windows.Forms.CheckBox;$reserveToggle.Text='备选账号';$reserveToggle.SetBounds(10,7,100,23);$reserveToggle.ForeColor=$color.ink;$reserveToggle.Checked=$false;$reserveToggle.Enabled=$false;$reservePanel.Controls.Add($reserveToggle)
$reserveNumber=New-Object Windows.Forms.NumericUpDown;$reserveNumber.SetBounds(116,6,56,25);$reserveNumber.Minimum=1;$reserveNumber.Maximum=1;$reserveNumber.Value=1;$reserveNumber.Enabled=$false;$reserveNumber.TextAlign='Center';$reserveNumber.BorderStyle='FixedSingle';$reservePanel.Controls.Add($reserveNumber)
$reserveTotalLabel=Label $reservePanel '/ 0 个' 181 8 65 22 9 $false 'muted'
$reserveHint=Label $overview '普通账号用完后启用' 658 147 340 24 9 $false 'muted'
$reserveTip=New-Object Windows.Forms.ToolTip
$reserveTip.SetToolTip($reserveToggle,'启动时按周剩余额度选定数量。本次名单固定，未选中的账号不会补入。')
$reserveTip.SetToolTip($reserveNumber,'停止看护后可重新选择备选数量。')
$reserveToggle.Add_CheckedChanged({$reserveNumber.Enabled=$reserveToggle.Enabled -and $reserveToggle.Checked})
$pauseReason=Label $overview '关闭窗口后继续在托盘运行。' 12 187 820 28 9 $false 'muted'
$reportButton=Button $overview '查看异常报告' 888 182 150;$reportButton.Visible=$false
$accountsHeading=Label $overview '账号列表' 12 227 300 25 11 $true
$sortHint=Label $overview '当前账号置顶，备选账号置底' 580 230 460 23 9 $false 'muted';$sortHint.TextAlign='MiddleRight'
$accountGrid=New-Object Windows.Forms.DataGridView
$accountGrid.SetBounds(12,261,1040,284);$accountGrid.BackgroundColor=[Drawing.Color]::White;$accountGrid.BorderStyle='None'
$accountGrid.ReadOnly=$true;$accountGrid.AllowUserToAddRows=$false;$accountGrid.AllowUserToDeleteRows=$false;$accountGrid.AllowUserToResizeRows=$false
$accountGrid.RowHeadersVisible=$false;$accountGrid.EnableHeadersVisualStyles=$false;$accountGrid.AutoSizeColumnsMode='Fill'
$accountGrid.SelectionMode='FullRowSelect';$accountGrid.MultiSelect=$false;$accountGrid.ScrollBars='Vertical'
$accountGrid.CellBorderStyle='SingleHorizontal';$accountGrid.GridColor=$color.border
$accountGrid.ColumnHeadersBorderStyle='None';$accountGrid.ColumnHeadersHeightSizeMode='DisableResizing';$accountGrid.ColumnHeadersHeight=34
$accountGrid.ColumnHeadersDefaultCellStyle.BackColor=$color.soft;$accountGrid.ColumnHeadersDefaultCellStyle.ForeColor=$color.ink
$accountGrid.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$accountGrid.RowTemplate.Height=30;$accountGrid.DefaultCellStyle.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
$accountGrid.DefaultCellStyle.ForeColor=$color.ink;$accountGrid.DefaultCellStyle.Padding=New-Object Windows.Forms.Padding(10,0,8,0)
$accountGrid.ColumnHeadersDefaultCellStyle.Padding=New-Object Windows.Forms.Padding(10,0,8,0)
$accountGrid.DefaultCellStyle.SelectionBackColor=[Drawing.ColorTranslator]::FromHtml('#DCE8F0');$accountGrid.DefaultCellStyle.SelectionForeColor=$color.ink
$accountGrid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#FAFCFB')
foreach($title in @('账号','五小时剩余','周剩余','五小时恢复时间','状态')){[void]$accountGrid.Columns.Add($title,$title)}
$accountGrid.Columns[0].FillWeight=280;$accountGrid.Columns[3].FillWeight=140;$accountGrid.Columns[4].FillWeight=130
$overview.Controls.Add($accountGrid);Initialize-AccountGridSorting $accountGrid
$eventsHeading=Label $overview '运行记录' 12 560 520 25 11 $true
$eventsBox=New-DashboardLogBox $overview 12 601 1040 100;$eventsBox.Text='启动看护后，这里会显示切号、恢复任务等重要事件。'
$followEvents=New-Object Windows.Forms.CheckBox;$followEvents.Text='跟随最新';$followEvents.Checked=$true;$followEvents.SetBounds(784,560,112,25);$overview.Controls.Add($followEvents)
$latestEvents=Button $overview '回到最新' 908 554 132
$latestEvents.Add_Click({$followEvents.Checked=$true;$eventsBox.SelectionStart=$eventsBox.TextLength;$eventsBox.SelectionLength=0;$eventsBox.ScrollToCaret()})

$scheduleHeading=Label $schedulePage '按你的时间开启额度窗口' 20 16 900 32 16 $true
$scheduleSummary=Label $schedulePage '设置每日执行时间，关闭窗口后仍会执行。' 20 55 1000 27 9 $false 'muted'
$settingsCard=Panel $schedulePage 20 100 1020 260
$timesCaption=Label $settingsCard '每日执行时间' 20 17 350 25 11 $true
$timesList=New-Object Windows.Forms.ListBox;$timesList.SetBounds(20,55,280,168);$timesList.Font=New-Object Drawing.Font('Segoe UI',18);$timesList.ForeColor=$color.ink;$timesList.SelectionMode='MultiExtended';$timesList.BorderStyle='FixedSingle';$settingsCard.Controls.Add($timesList)
$config=Get-ScheduleConfig;foreach($time in @($config.times)){[void]$timesList.Items.Add([string]$time)}
$scheduleSummary.Text=$(if($config.enabled -and @($config.times).Count){'已启用，每天 '+(@($config.times)-join '、')+' 执行'}else{'定时未启用，添加时间后保存即可启用。'})
$timeCaption=Label $settingsCard '添加一个时间' 328 18 280 24 9 $false 'muted'
$timePicker=New-Object Windows.Forms.DateTimePicker;$timePicker.SetBounds(328,55,130,30);$timePicker.Format='Custom';$timePicker.CustomFormat='HH:mm';$timePicker.ShowUpDown=$true;$settingsCard.Controls.Add($timePicker)
$addTime=Button $settingsCard '添加' 470 51 104
$removeTime=Button $settingsCard '移除选中' 328 100 118;$clearTime=Button $settingsCard '清空列表' 458 100 116
$saveButton=Button $settingsCard '保存并启用' 328 184 136 $true;$disableButton=Button $settingsCard '停用定时' 476 184 112
$portDivider=Panel $settingsCard 622 20 1 210;$portDivider.BackColor=$color.border
$portCaption=Label $settingsCard '本机连接' 648 18 300 25 11 $true
$portHint=Label $settingsCard 'Codex Switch 监听端口' 648 55 300 23 9 $false 'muted'
$portBox=New-Object Windows.Forms.NumericUpDown;$portBox.SetBounds(648,88,118,29);$portBox.Minimum=1;$portBox.Maximum=65535;$portBox.Value=$config.port;$settingsCard.Controls.Add($portBox)
$testButton=Button $settingsCard '测试连接' 778 85 112
$scheduleNote=Label $settingsCard "电脑需保持登录。`n定时独立于看护运行。" 648 145 310 60 9 $false 'muted'
$consumeButton=Button $schedulePage '立即消耗一次' 20 380 160
$consumeHint=Label $schedulePage '对有额度的普通账号各消耗一次；执行前需确认。' 196 388 800 27 9 $false 'muted'
$scheduleLogHeading=Label $schedulePage '执行记录' 20 444 520 26 11 $true
$scheduleLog=New-DashboardLogBox $schedulePage 20 488 1020 180
$followSchedule=New-Object Windows.Forms.CheckBox;$followSchedule.Text='跟随最新';$followSchedule.Checked=$true;$followSchedule.SetBounds(772,444,112,25);$schedulePage.Controls.Add($followSchedule)
$latestSchedule=Button $schedulePage '回到最新' 896 438 132
$latestSchedule.Add_Click({$followSchedule.Checked=$true;$scheduleLog.SelectionStart=$scheduleLog.TextLength;$scheduleLog.SelectionLength=0;$scheduleLog.ScrollToCaret()})
$connection=Label $form '正在连接 Codex Switch…' 28 827 730 22 9 $false 'muted'
$notice=Label $form '' 28 802 800 23 9 $false 'accent'
$hideButton=Button $form '收回托盘' 960 811 132
foreach($box in @($eventsBox,$scheduleLog)){$box.BorderStyle='None';$box.BackColor=[Drawing.Color]::White;$box.ForeColor=$color.muted}
$script:ActiveAccountFont=New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)

function Set-LayoutBounds($Control,$X,$Y,$Width,$Height){
    $scale=$form.CurrentAutoScaleDimensions.Width/96.0
    $Control.SetBounds([int]($X*$scale),[int]($Y*$scale),[int]($Width*$scale),[int]($Height*$scale))
}
function Resize-DashboardLayout {
    $scale=$form.CurrentAutoScaleDimensions.Width/96.0
    $w=$form.ClientSize.Width/$scale;$h=$form.ClientSize.Height/$scale
    Set-LayoutBounds $header 0 0 $w 86
    Set-LayoutBounds $statusLabel ($w-204) 18 176 29
    Set-LayoutBounds $elapsedValue ($w-300) 53 272 22
    Set-LayoutBounds $tabs 24 99 ($w-48) ($h-162)
    Set-LayoutBounds $connection 28 ($h-33) ($w-220) 22
    Set-LayoutBounds $notice 28 ($h-58) ($w-220) 23
    Set-LayoutBounds $hideButton ($w-160) ($h-49) 132 36
    $pw=$overview.ClientSize.Width/$scale;$ph=$overview.ClientSize.Height/$scale
    Set-LayoutBounds $summaryPanel 12 14 ($pw-24) 100
    Set-LayoutBounds $summaryAccent 0 0 4 100
    $sw=$pw-24
    Set-LayoutBounds $currentLabel 20 38 ($sw-438) 31
    Set-LayoutBounds $runDetail 20 73 ($sw-438) 22
    Set-LayoutBounds $fiveCaption ($sw-388) 14 154 23
    Set-LayoutBounds $fiveValue ($sw-388) 37 154 38
    Set-LayoutBounds $fiveTrack ($sw-388) 84 154 5
    Set-LayoutBounds $weekCaption ($sw-194) 14 170 23
    Set-LayoutBounds $weekValue ($sw-194) 37 170 38
    Set-LayoutBounds $weekTrack ($sw-194) 84 170 5
    Set-LayoutBounds $startButton 12 128 124 36
    Set-LayoutBounds $pauseButton 148 128 104 36
    Set-LayoutBounds $stopButton 264 128 104 36
    Set-LayoutBounds $reservePanel 392 128 250 36
    Set-LayoutBounds $reserveHint 658 135 ($pw-670) 24
    Set-LayoutBounds $pauseReason 12 175 ($pw-190) 28
    Set-LayoutBounds $reportButton ($pw-162) 167 150 34
    Set-LayoutBounds $accountsHeading 12 207 300 25
    Set-LayoutBounds $sortHint ($pw-472) 209 460 23
    $gridHeight=[Math]::Min(390,[Math]::Max(200,$ph-390))
    Set-LayoutBounds $accountGrid 12 241 ($pw-24) $gridHeight
    $eventTop=241+$gridHeight+16
    Set-LayoutBounds $eventsHeading 12 ($eventTop+6) 520 25
    Set-LayoutBounds $latestEvents ($pw-144) $eventTop 132 34
    Set-LayoutBounds $followEvents ($pw-268) ($eventTop+5) 112 25
    Set-LayoutBounds $eventsBox 12 ($eventTop+42) ($pw-24) ([Math]::Max(60,$ph-$eventTop-54))
    $spw=$schedulePage.ClientSize.Width/$scale;$sph=$schedulePage.ClientSize.Height/$scale
    Set-LayoutBounds $settingsCard 20 100 ($spw-40) 260
    Set-LayoutBounds $scheduleSummary 20 55 ($spw-40) 27
    Set-LayoutBounds $latestSchedule ($spw-152) 438 132 34
    Set-LayoutBounds $followSchedule ($spw-276) 443 112 25
    Set-LayoutBounds $scheduleLog 20 482 ($spw-40) ([Math]::Max(80,$sph-496))
    Update-QuotaMeters
}
function Update-QuotaMeters {
    foreach($entry in @(@($fiveValue,$fiveTrack,$fiveFill),@($weekValue,$weekTrack,$weekFill))){
        $text=$entry[0].Text;$value=0.0
        $valid=$text.EndsWith('%') -and [double]::TryParse($text.TrimEnd('%'),[ref]$value)
        $entry[2].Width=if($valid){[int]($entry[1].ClientSize.Width*[Math]::Max(0,[Math]::Min(100,$value))/100)}else{0}
        $entry[2].Height=$entry[1].ClientSize.Height
        $tone=if($valid -and $value -le 15){$color.warning}else{$color.accent}
        $entry[2].BackColor=$tone;$entry[0].ForeColor=$tone
    }
}
$form.Add_Resize({Resize-DashboardLayout})
$tabs.Add_SelectedIndexChanged({Resize-DashboardLayout})
