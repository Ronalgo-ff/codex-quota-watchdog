# Real WinForms controls and command files, isolated from every account service.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-reserve-ui-'+[guid]::NewGuid().ToString('N'))
$fixture=@'
$form.ShowInTaskbar=$false;$form.Opacity=0;$form.Show();[Windows.Forms.Application]::DoEvents()
$script:passed=0
function Assert-UI($Name,$OK){if(-not $OK){throw "UI assertion failed: $Name"};$script:passed++;Write-Host "[PASS] $Name"}
$script:accounts=@(1..3|ForEach-Object {[pscustomobject]@{id="r$_";email="r$_@test";active=$false;usage=@{primary=@{windowMinutes=10080;remainingPercent=100};secondary=$null;error=$null}}})
$script:accounts+=[pscustomobject]@{id='a1';email='a1@test';active=$true;usage=@{primary=@{windowMinutes=300;remainingPercent=50};secondary=@{windowMinutes=10080;remainingPercent=50};error=$null}}
$script:accountError='';Render-Accounts
Assert-UI 'front end has no dry-run control' (@($overview.Controls|Where-Object {$_.Text -match '演习'}).Count -eq 0)
Assert-UI 'reserve starts unchecked with disabled number and actual total' (-not $reserveToggle.Checked -and -not $reserveNumber.Enabled -and $reserveNumber.Maximum -eq 3 -and $reserveTotalLabel.Text -eq '/ 3 个')
$reserveToggle.Checked=$true
Assert-UI 'checkbox enables bounded reserve count in compact panel' ($reserveNumber.Enabled -and $reserveNumber.Minimum -eq 1 -and $reservePanel.Width -lt 280)
$reserveNumber.Value=2;$startButton.PerformClick()
$command=Read-DashboardJson (Join-Path $Here 'state\tray-host-command.json')
Assert-UI 'start button sends this run count without invoking account APIs' ($command.action -eq 'start-live' -and $command.options.reserveCount -eq 2)
$script:commandId=$null;$at=(Get-Date).ToString('o')
Write-ScheduleJson (Join-Path $Here 'state\current-run.json') @{pid=$PID;id='fixture-run';processStartedAt=(Get-Process -Id $PID).StartTime.ToString('o');startedAt=$at;mode='正常模式';reserveRequestedCount=2;eventFile=(Join-Path $Here 'logs\fixture.log')}
Write-ScheduleJson (Join-Path $Here 'state\quota-status.json') @{pid=$PID;desktopHealth=@{mode='ok'};waitingReset=$null;reservePolicy=@{selectedIds=@('r1','r2');knownReserveIds=@('r1','r2','r3')}}
Refresh-UI;Render-Accounts
Assert-UI 'running locks reserve setting and start button' (-not $reserveToggle.Enabled -and -not $reserveNumber.Enabled -and -not $startButton.Enabled -and $reserveNumber.Value -eq 2)
$rows=@($accountGrid.Rows|ForEach-Object {$_.Cells[4].Value})
Assert-UI 'account grid distinguishes selected and unselected reserves' (@($rows|Where-Object {$_ -eq '本次备选'}).Count -eq 2 -and @($rows|Where-Object {$_ -eq '备选未启用'}).Count -eq 1)
$script:accounts=@($script:accounts|Where-Object {$_.id -in @('a1','r1')});Render-Accounts
Assert-UI 'removing reserves never rewrites locked run count' ($reserveNumber.Value -eq 2 -and -not $reserveNumber.Enabled)
$reserveToggle.Checked=$false;$reserveNumber.Value=1;$script:lastActiveRunId=$null
Refresh-UI
Assert-UI 'reopened view restores the current run selection' ($reserveToggle.Checked -and $reserveNumber.Value -eq 2 -and -not $reserveToggle.Enabled)
Write-ScheduleJson (Join-Path $Here 'state\current-run.json') @{pid=2147483647;processStartedAt=$at}
Refresh-UI
Assert-UI 'stopping returns reserve choice to default off' (-not $reserveToggle.Checked -and $reserveNumber.Value -eq 1 -and $startButton.Enabled)
foreach($size in @(@(1040,780),@(1500,1050),@(1120,900))){
    $form.ClientSize=New-Object Drawing.Size($size[0],$size[1]);[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
    Assert-UI ('account list and records fit after resizing to '+($size -join 'x')) ($accountGrid.Right -le $overview.ClientSize.Width -and $accountGrid.Bottom -lt $eventsHeading.Top -and $eventsBox.Top -gt $latestEvents.Bottom -and $eventsBox.Bottom -le $overview.ClientSize.Height -and $eventsBox.Height -ge 50)
    $tabs.SelectedTab=$schedulePage;[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
    Assert-UI ('schedule controls and records fit after resizing to '+($size -join 'x')) ($settingsCard.Right -le $schedulePage.ClientSize.Width -and $testButton.Right -le $settingsCard.ClientSize.Width -and $scheduleLog.Top -gt $latestSchedule.Bottom -and $scheduleLog.Bottom -le $schedulePage.ClientSize.Height)
    $tabs.SelectedTab=$overview
}
$fiveValue.Text='12%';$weekValue.Text='74%';Update-QuotaMeters
Assert-UI 'quota meters reflect actual values and low quota color' ([Math]::Abs($fiveFill.Width/$fiveTrack.ClientSize.Width-0.12) -lt 0.01 -and $fiveValue.ForeColor -eq $color.warning -and [Math]::Abs($weekFill.Width/$weekTrack.ClientSize.Width-0.74) -lt 0.01)
$fiveValue.Text='无此限制';Update-QuotaMeters
Assert-UI 'unlimited quota does not display an invented full meter' ($fiveFill.Width -eq 0)
Set-DashboardLogText $eventsBox @('看护已启动','当前账号额度正常','已恢复中断任务') $true
[Windows.Forms.Application]::DoEvents()
$last=$eventsBox.GetPositionFromCharIndex($eventsBox.TextLength-1)
Assert-UI 'event text remains visible in the redesigned history area' ($eventsBox.Visible -and $eventsBox.Text.Contains('已恢复中断任务') -and $last.Y -ge 0 -and $last.Y -lt $eventsBox.ClientSize.Height -and $eventsBox.ForeColor -ne $eventsBox.BackColor)
Write-Host "Passed $script:passed; failed 0"
$form.Hide()
'@
try{
    $null=New-Item -ItemType Directory $tmp -Force
    Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse
    $text=Get-Content (Join-Path $root 'dashboard.ps1') -Raw -Encoding UTF8
    $text=$text.Replace('Refresh-UI;$script:timer=New-Object', $fixture+"`nRefresh-UI;`$script:timer=New-Object")
    [IO.File]::WriteAllText((Join-Path $tmp 'dashboard.ps1'),$text,(New-Object Text.UTF8Encoding($true)))
    & powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $tmp 'dashboard.ps1') -SmokeTest
    if($LASTEXITCODE -ne 0){throw 'Reserve UI regression failed'}
}finally{Remove-TestDirectory $tmp}
