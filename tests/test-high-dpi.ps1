# Exercise the actual dashboard in an isolated directory at the display's DPI.
[CmdletBinding()]
param([string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-high-dpi-'+[guid]::NewGuid().ToString('N'))
$fixture=@'
$form.ShowInTaskbar=$false;$form.Opacity=0
if($env:QUOTA_DPI_TEST_SCREEN){
 $startScreen=@([Windows.Forms.Screen]::AllScreens)[[int]$env:QUOTA_DPI_TEST_SCREEN]
 $form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(($startScreen.WorkingArea.Left+40),($startScreen.WorkingArea.Top+40))
}
$form.Show();[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DpiTestNative {
 [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
"@
function Assert-Dpi($Name,$OK){if(-not $OK){throw "DPI assertion failed: $Name"};Write-Host "[PASS] $Name"}
function Assert-AbsoluteFonts {
 $factor=$form.DeviceDpi/96.0
 foreach($expected in @(@($form,12),@($brand,24),@($currentLabel,(16*96.0/72)),@($fiveValue,32),@($weekValue,32))){
  Assert-Dpi ('original design font size for '+$expected[0].Text) ($expected[0].Font.Unit -eq [Drawing.GraphicsUnit]::Pixel -and [Math]::Abs($expected[0].Font.Size-$expected[1]*$factor) -lt 0.02)
 }
 foreach($entry in $script:dashboardDpiModel){
  if($entry.control -is [Windows.Forms.RichTextBox]){continue}
  $actual=$entry.control.Font;$pixels=$entry.points*$form.DeviceDpi/72.0
  Assert-Dpi ('absolute pixel font for '+$entry.control.GetType().Name+' '+$entry.control.Text) ($actual.Unit -eq [Drawing.GraphicsUnit]::Pixel -and [Math]::Abs($actual.Size-$pixels) -lt 0.02)
 }
 foreach($label in @($brand,$currentLabel,$fiveValue,$weekValue)){
  $measured=[Windows.Forms.TextRenderer]::MeasureText($label.Text,$label.Font,[Drawing.Size]::Empty,([Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::SingleLine))
  Assert-Dpi ('complete text height for '+$label.Text+' at '+$form.DeviceDpi+' DPI ('+$measured.Height+' within '+$label.ClientSize.Height+')') ($measured.Height -le $label.ClientSize.Height)
 }
}
$dpi=[DpiTestNative]::GetDpiForWindow($form.Handle);$scale=$dpi/96.0
$script:accounts=@([pscustomobject]@{id='sample';email='account@example.com';active=$true;usage=@{error=$null;primary=@{remainingPercent=62;windowMinutes=300};secondary=@{remainingPercent=78;windowMinutes=10080}}})
$script:accountError='';Render-Accounts
$metrics=@{dpi=$dpi;windowDpi=[DpiTestNative]::GetDpiForWindow($form.Handle);awareness=[DpiTestNative]::GetAwarenessFromDpiAwarenessContext([DpiTestNative]::GetWindowDpiAwarenessContext($form.Handle));scale=$scale;clientWidth=$form.ClientSize.Width;clientHeight=$form.ClientSize.Height;rowHeight=$accountGrid.RowTemplate.Height;headerHeight=$accountGrid.ColumnHeadersHeight;brandWidth=$brand.Width;brandHeight=$brand.Height;reserveWidth=$reservePanel.Width;reserveNumberRight=$reserveNumber.Right;autoScale=$form.CurrentAutoScaleDimensions.Width}
$metrics|ConvertTo-Json|Set-Content (Join-Path $Here 'dpi-metrics.json') -Encoding UTF8
$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $Here 'dpi-overview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
Assert-Dpi 'window is per-monitor aware and managed DPI matches the native window' ($metrics.awareness -eq 2 -and $form.DeviceDpi -eq $dpi)
# WinForms versions differ slightly when resizing the initial non-client frame.
Assert-Dpi 'initial window is scaled once from the 96-DPI design' ([Math]::Abs($form.ClientSize.Width-1120*$scale) -le 16 -and [Math]::Abs($form.ClientSize.Height-900*$scale) -le 16)
Assert-Dpi 'nested caption and reserve controls use the same scale' ([Math]::Abs($brand.Left-28*$scale) -le 2 -and [Math]::Abs($brand.Height-32*$scale) -le 2 -and $reserveNumber.Right -lt $reservePanel.ClientSize.Width)
Assert-Dpi 'account rows leave room for native-resolution text' ($accountGrid.RowTemplate.Height -ge [Math]::Round(30*$scale)-1 -and $accountGrid.Rows[0].Height -ge [Math]::Round(30*$scale)-1)
Assert-Dpi 'account headers scale with the text' ($accountGrid.ColumnHeadersHeight -ge [Math]::Round(34*$scale)-1)
foreach($size in @(@(1040,780),@(1500,1050),@(1120,900))){
 $form.ClientSize=New-Object Drawing.Size([int]($size[0]*$scale),[int]($size[1]*$scale));[Windows.Forms.Application]::DoEvents();Save-DashboardWindowSize;Resize-DashboardLayout
 Assert-Dpi ('overview fits at logical size '+($size -join 'x')) ($accountGrid.Right -le $overview.ClientSize.Width -and $accountGrid.Bottom -lt $eventsHeading.Top -and $eventsBox.Top -gt $latestEvents.Bottom -and $eventsBox.Bottom -le $overview.ClientSize.Height)
 $tabs.SelectedTab=$schedulePage;[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
 Assert-Dpi ('schedule fits at logical size '+($size -join 'x')) ($testButton.Right -le $settingsCard.ClientSize.Width -and $saveButton.Bottom -le $settingsCard.ClientSize.Height -and $scheduleLog.Top -gt $latestSchedule.Bottom -and $scheduleLog.Bottom -le $schedulePage.ClientSize.Height)
 $tabs.SelectedTab=$overview
}
$tabs.SelectedTab=$schedulePage;[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $Here 'dpi-schedule.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
$tabs.SelectedTab=$overview
$script:dpiChanges=0;$form.Add_DpiChanged({$script:dpiChanges++})
$monitorResults=@();$screens=@([Windows.Forms.Screen]::AllScreens)
$eventsBox.Text="Log first line`r`nLog second line"
$form.ClientSize=New-Object Drawing.Size([int](1120*$form.DeviceDpi/96.0),[int](900*$form.DeviceDpi/96.0));[Windows.Forms.Application]::DoEvents();Save-DashboardWindowSize
$logicalWidth=$form.ClientSize.Width*96.0/$form.DeviceDpi;$logicalHeight=$form.ClientSize.Height*96.0/$form.DeviceDpi
# Move only this invisible test form; Windows sends real DPI-change messages.
# Two round trips detect stale DPI, cumulative scaling and missed return moves.
$route=@($screens)+@($screens[($screens.Count-1)..0])+@($screens)+@($screens[($screens.Count-1)..0])
foreach($screen in $route){
 $form.Location=New-Object Drawing.Point(($screen.WorkingArea.Left+40),($screen.WorkingArea.Top+40))
 1..3|ForEach-Object {[Windows.Forms.Application]::DoEvents()}
 $nativeDpi=[DpiTestNative]::GetDpiForWindow($form.Handle);$factor=$nativeDpi/96.0
 Assert-Dpi ('native and managed DPI match on '+$screen.DeviceName) ($form.DeviceDpi -eq $nativeDpi)
 Assert-AbsoluteFonts
 Assert-Dpi ('round trips preserve logical window size on '+$screen.DeviceName) ([Math]::Abs($form.ClientSize.Width/$factor-$logicalWidth) -le 2 -and [Math]::Abs($form.ClientSize.Height/$factor-$logicalHeight) -le 2)
 Assert-Dpi ('nested text bounds follow monitor DPI on '+$screen.DeviceName) ([Math]::Abs($brand.Left-28*$factor) -le 2 -and [Math]::Abs($brand.Height-32*$factor) -le 2)
 Assert-Dpi ('table metrics follow monitor DPI on '+$screen.DeviceName) ($accountGrid.RowTemplate.Height -eq [int][Math]::Round(30*$factor) -and $accountGrid.Rows[0].Height -eq [int][Math]::Round(30*$factor) -and $accountGrid.ColumnHeadersHeight -eq [int][Math]::Round(34*$factor))
 Assert-Dpi ('table fonts follow native text scaling on '+$screen.DeviceName) ($accountGrid.DefaultCellStyle.Font.Equals($form.Font) -and $accountGrid.ColumnHeadersDefaultCellStyle.Font.Equals($form.Font) -and [Math]::Abs($script:ActiveAccountFont.SizeInPoints-$form.Font.SizeInPoints) -lt 0.01)
 Render-Accounts
 Assert-Dpi ('refreshed active row retains the scaled font on '+$screen.DeviceName) ([Math]::Abs($accountGrid.Rows[0].Cells[0].Style.Font.SizeInPoints-$form.Font.SizeInPoints) -lt 0.01)
 Assert-Dpi ('overview remains within the window on '+$screen.DeviceName) ($accountGrid.Right -le $overview.ClientSize.Width -and $eventsBox.Bottom -le $overview.ClientSize.Height -and $reserveNumber.Right -lt $reservePanel.Width)
 Set-DashboardLogText $eventsBox @('Log first line','Log second line') $true
 [Windows.Forms.Application]::DoEvents()
 $lineHeight=$eventsBox.GetPositionFromCharIndex($eventsBox.GetFirstCharIndexFromLine(1)).Y-$eventsBox.GetPositionFromCharIndex(0).Y
 # RichEdit versions use different line leading; verify native point size as
 # well as visible line height so cumulative font shrinkage cannot pass.
 Assert-Dpi ('log text stays readable after monitor changes and refresh on '+$screen.DeviceName) ([QuotaUiDpi]::GetLogFontTwips($eventsBox.Handle) -eq 180 -and $lineHeight -ge 13*$factor -and $lineHeight -le 40*$factor)
 $tabs.SelectedTab=$schedulePage;[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
 Assert-Dpi ('schedule controls fit after monitor changes on '+$screen.DeviceName) ($portBox.Right -lt $settingsCard.Width -and $saveButton.Bottom -lt $settingsCard.Height -and $scheduleLog.Bottom -le $schedulePage.ClientSize.Height -and [Math]::Abs($timesList.Left-20*$factor) -le 2)
 Set-DashboardLogText $scheduleLog @('Schedule first line','Schedule second line') $true
 [Windows.Forms.Application]::DoEvents()
 $scheduleLineHeight=$scheduleLog.GetPositionFromCharIndex($scheduleLog.GetFirstCharIndexFromLine(1)).Y-$scheduleLog.GetPositionFromCharIndex(0).Y
 Assert-Dpi ('schedule log stays readable on '+$screen.DeviceName) ([QuotaUiDpi]::GetLogFontTwips($scheduleLog.Handle) -eq 180 -and $scheduleLineHeight -ge 13*$factor -and $scheduleLineHeight -le 40*$factor)
 $tabs.SelectedTab=$overview;[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
 # A real user may maximize, restore, resize, then drag to the next display.
 $form.WindowState='Maximized';[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout;Assert-AbsoluteFonts
 $form.WindowState='Normal';[Windows.Forms.Application]::DoEvents();Resize-DashboardLayout
 Assert-Dpi ('restore preserves logical window size on '+$screen.DeviceName) ([Math]::Abs($form.ClientSize.Width/$factor-$logicalWidth) -le 2 -and [Math]::Abs($form.ClientSize.Height/$factor-$logicalHeight) -le 2)
 $monitorResults+=@{screen=$screen.DeviceName;bounds=$screen.Bounds.ToString();dpi=$nativeDpi;managedDpi=$form.DeviceDpi;brandHeight=$brand.Height;rowHeight=$accountGrid.Rows[0].Height;fontSize=$brand.Font.SizeInPoints;changes=$script:dpiChanges}
 $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
 try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $Here ('dpi-monitor-'+$nativeDpi+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
$monitorResults|ConvertTo-Json|Set-Content (Join-Path $Here 'dpi-monitors.json') -Encoding UTF8
if(@($monitorResults.dpi|Select-Object -Unique).Count -gt 1){Assert-Dpi 'real mixed-DPI round trips raised DPI-change events' ($script:dpiChanges -ge 2)}
$form.Hide()
'@
try{
 $null=New-Item -ItemType Directory $tmp -Force
 Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse
 $text=Get-Content (Join-Path $root 'dashboard.ps1') -Raw -Encoding UTF8
 $text=$text.Replace('Refresh-UI;$script:timer=New-Object',$fixture+"`nRefresh-UI;`$script:timer=New-Object")
 [IO.File]::WriteAllText((Join-Path $tmp 'dashboard.ps1'),$text,(New-Object Text.UTF8Encoding($true)))
 $shells=@((Get-Command powershell.exe).Source)
 $pwsh=Get-Command pwsh.exe -ErrorAction SilentlyContinue
 if($pwsh){$shells+=$pwsh.Source}
 Add-Type -AssemblyName System.Windows.Forms
 $screenCount=[Windows.Forms.Screen]::AllScreens.Count
 foreach($shell in $shells){foreach($startScreenIndex in 0..($screenCount-1)){
  $env:QUOTA_DPI_TEST_SCREEN=[string]$startScreenIndex
  Write-Host ('DPI validation: '+$shell)
  & $shell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $tmp 'dashboard.ps1') -SmokeTest
  $result=$LASTEXITCODE
  if($EvidenceDirectory){
   $dest=Join-Path $EvidenceDirectory (([IO.Path]::GetFileNameWithoutExtension($shell))+'-screen'+$startScreenIndex);$null=New-Item -ItemType Directory $dest -Force
   Get-ChildItem -LiteralPath $tmp -File -Filter 'dpi-*'|Copy-Item -Destination $dest -Force
  }
  if($result -ne 0){throw ('High DPI regression failed: '+$shell)}
 }}
}finally{Remove-Item Env:\QUOTA_DPI_TEST_SCREEN -ErrorAction SilentlyContinue;Remove-TestDirectory $tmp}
