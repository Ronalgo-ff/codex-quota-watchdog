# Own off-screen WinForms controls only; no real watcher or account operations.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\log-view.ps1')
$pass=0;$fail=0
function Check($Name,$Ok){if($Ok){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
$form=New-Object Windows.Forms.Form;$form.ShowInTaskbar=$false;$form.Opacity=0
$form.ClientSize=New-Object Drawing.Size(1010,650)
$panel=New-Object Windows.Forms.Panel;$panel.Dock='Fill';$form.Controls.Add($panel)
$button=New-Object Windows.Forms.Button;$button.SetBounds(825,400,156,36);$panel.Controls.Add($button)
$check=New-Object Windows.Forms.CheckBox;$check.SetBounds(690,404,112,25);$panel.Controls.Add($check)
$box=New-DashboardLogBox $panel 12 434 972 107
try{
    $form.Show();[Windows.Forms.Application]::DoEvents()
    Resize-DashboardLogBox $panel $box $button $check
    $lines=@(1..120|ForEach-Object {"message $_ "+('长消息自动换行。'*30)})
    Set-DashboardLogText $box $lines $true;[Windows.Forms.Application]::DoEvents()
    Check 'vertical scrollbar stays enabled and long lines wrap' ($box.ScrollBars -eq 'ForcedVertical' -and $box.WordWrap)
    $last=$box.GetPositionFromCharIndex($box.TextLength-1)
    Check 'follow mode makes newest event visible' ($last.Y -ge 0 -and $last.Y -lt $box.ClientSize.Height)
    $box.SelectionStart=0;$box.SelectionLength=0;$box.ScrollToCaret()
    Set-DashboardLogText $box ($lines+@('new event')) $false;[Windows.Forms.Application]::DoEvents()
    Check 'history reading is preserved when follow mode is off' ($box.GetCharIndexFromPosition((New-Object Drawing.Point(2,2))) -lt 100)
    Set-DashboardLogText $box ($lines+@('LATEST EVENT')) $true
    $last=$box.GetPositionFromCharIndex($box.TextLength-1)
    Check 'latest event remains readable without horizontal expansion' ($last.X -lt $box.ClientSize.Width -and $last.Y -ge 0 -and $last.Y -lt $box.ClientSize.Height)
    foreach($size in @(@(1010,588),@(1500,950),@(1010,588))){
        $form.ClientSize=New-Object Drawing.Size($size[0],$size[1]);[Windows.Forms.Application]::DoEvents()
        Resize-DashboardLogBox $panel $box $button $check
        Check ("log bounds fit parent after resize to "+($size -join 'x')) ($box.Right -le $panel.ClientSize.Width-10 -and $box.Bottom -le $panel.ClientSize.Height-10 -and $box.Top -ge $button.Bottom -and $box.Height -gt 40)
    }
}finally{$form.Close();$form.Dispose()}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
