# Keep one immutable 96-DPI design. Every monitor change derives geometry and
# pixel fonts from it; never multiply a font left over from another monitor.
function Get-DashboardPixelFont([string]$Family,[single]$Points,[Drawing.FontStyle]$Style) {
    $dpi=$form.DeviceDpi
    $key=$Family+'|'+$Points+'|'+$Style+'|'+$dpi
    if(-not $script:dashboardFonts.ContainsKey($key)){
        $script:dashboardFonts[$key]=New-Object Drawing.Font($Family,[single]($Points*$dpi/72.0),$Style,[Drawing.GraphicsUnit]::Pixel)
    }
    return $script:dashboardFonts[$key]
}

function Initialize-DashboardDpiModel {
    $script:dashboardFonts=@{}
    $script:dashboardDpiModel=New-Object 'Collections.Generic.List[object]'
    function Save-DesignControl($Control) {
        if($Control -is [Windows.Forms.ContainerControl]){$Control.AutoScaleMode='None'}
        $script:dashboardDpiModel.Add([pscustomobject]@{
            control=$Control;bounds=$Control.Bounds;family=$Control.Font.FontFamily.Name
            points=$Control.Font.SizeInPoints;style=$Control.Font.Style;padding=$Control.Padding
        })
        # Framework-owned edit boxes, scrollbars and spinner buttons are laid
        # out by their owner, not by the application's design coordinates.
        if($Control -is [Windows.Forms.Form] -or $Control -is [Windows.Forms.Panel] -or $Control -is [Windows.Forms.TabControl]){
            foreach($child in $Control.Controls){Save-DesignControl $child}
        }
    }
    Save-DesignControl $form
    $script:dashboardAppliedDpi=0
    $script:dashboardLayoutBusy=$false
}

function Set-DashboardDpiStyles {
    $geometryChanged=$script:dashboardAppliedDpi -ne $form.DeviceDpi
    $scale=$form.DeviceDpi/96.0
    foreach($entry in $script:dashboardDpiModel){
        $control=$entry.control
        # A previously hidden tab can receive framework font changes when its
        # handle is created later. Reassert fonts even if the form DPI is stable.
        $font=Get-DashboardPixelFont $entry.family $entry.points $entry.style
        if(-not $control.Font.Equals($font)){$control.Font=$font}
        if(-not $geometryChanged){continue}
        if($control -ne $form){
            $bounds=$entry.bounds
            $control.SetBounds([int][Math]::Round($bounds.X*$scale),[int][Math]::Round($bounds.Y*$scale),[int][Math]::Round($bounds.Width*$scale),[int][Math]::Round($bounds.Height*$scale))
        }
        $padding=$entry.padding
        if($padding -is [Windows.Forms.Padding]){
            $control.Padding=New-Object Windows.Forms.Padding([int]($padding.Left*$scale),[int]($padding.Top*$scale),[int]($padding.Right*$scale),[int]($padding.Bottom*$scale))
        }elseif($padding -is [Drawing.Point]){
            $control.Padding=New-Object Drawing.Point([int]($padding.X*$scale),[int]($padding.Y*$scale))
        }
    }
    $form.MinimumSize=New-Object Drawing.Size([int](1056*$scale),[int](819*$scale))
    $script:ActiveAccountFont=Get-DashboardPixelFont 'Microsoft YaHei UI' 9 ([Drawing.FontStyle]::Bold)
    $script:dashboardAppliedDpi=$form.DeviceDpi
}
