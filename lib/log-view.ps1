# RichEdit keeps a usable vertical scrollbar even with borderless themed controls.
function New-DashboardLogBox($Parent,$X,$Y,$Width,$Height) {
    $box=New-Object Windows.Forms.RichTextBox
    $box.Multiline=$true;$box.ReadOnly=$true;$box.WordWrap=$true
    $box.ScrollBars='ForcedVertical';$box.BorderStyle='FixedSingle'
    $box.BackColor=[Drawing.Color]::White
    $box.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $box.DetectUrls=$false;$box.HideSelection=$false
    $Parent.Controls.Add($box)
    $box.Location=New-Object Drawing.Point($X,$Y)
    $box.Size=New-Object Drawing.Size($Width,$Height)
    $box.Anchor='Top,Left'
    return $box
}
function Resize-DashboardLogBox($Parent,$Box,$Button,$CheckBox) {
    $margin=$Box.Left
    $Button.Left=[Math]::Max($margin,$Parent.ClientSize.Width-$margin-$Button.Width)
    $CheckBox.Left=[Math]::Max($margin,$Button.Left-$CheckBox.Width-12)
    $top=$Button.Bottom+6
    $Box.SetBounds($margin,$top,[Math]::Max(100,$Parent.ClientSize.Width-2*$margin),[Math]::Max(40,$Parent.ClientSize.Height-$top-12))
}
function Set-DashboardLogText($Box,[string[]]$Lines,[bool]$FollowLatest) {
    # Preserve the viewport while reading history, including after new events arrive.
    $first=$Box.GetCharIndexFromPosition((New-Object Drawing.Point(1,1)))
    $selection=$Box.SelectionStart;$length=$Box.SelectionLength
    $Box.Lines=$Lines
    if($FollowLatest){$Box.SelectionStart=$Box.TextLength;$Box.SelectionLength=0;$Box.ScrollToCaret()}
    else{
        $Box.SelectionStart=[Math]::Min($first,$Box.TextLength);$Box.SelectionLength=0;$Box.ScrollToCaret()
        # Restoring selection does not scroll, so the user's highlight stays intact.
        $Box.Select([Math]::Min($selection,$Box.TextLength),[Math]::Min($length,[Math]::Max(0,$Box.TextLength-$selection)))
    }
}
