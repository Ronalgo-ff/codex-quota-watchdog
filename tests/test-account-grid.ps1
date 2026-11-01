# Real grid: pinned current account, independent reserves and selected column order.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-account-grid-'+[guid]::NewGuid().ToString('N'))
$fixture=@'
$form.ShowInTaskbar=$false;$form.Opacity=0;$form.Show();[Windows.Forms.Application]::DoEvents()
$script:passed=0
function Assert-Grid($Name,$OK){if(-not $OK){throw "Grid assertion failed: $Name"};$script:passed++;Write-Host "[PASS] $Name"}
function New-AccountRow($Id,$Email,$Active,$Five,$Week,$Reset){
    return [pscustomobject]@{id=$Id;email=$Email;active=$Active;usage=@{error=$null;primary=@{windowMinutes=300;remainingPercent=$Five;resetsAt=$Reset};secondary=@{windowMinutes=10080;remainingPercent=$Week}}}
}
$script:accounts=@((New-AccountRow 'b' 'bravo@test' $false 100 56 2000000100),(New-AccountRow 'd' 'delta@test' $true 62 61 2000000200),(New-AccountRow 'a' 'alpha@test' $false 0 81 2000000300),(New-AccountRow 'c' 'charlie@test' $false 9 46 2000000400))
foreach($item in @(@('r-high',100),@('r-low',5),@('r-mid',50),@('r-unknown',$null))){
    $script:accounts+=[pscustomobject]@{id=$item[0];email=($item[0]+'@test');active=$false;usage=@{primary=@{windowMinutes=10080;remainingPercent=$item[1]};secondary=$null;error=$null}}
}
$script:accountError='';Render-Accounts
Assert-Grid 'default order pins current then ordinary weekly descending and reserve weekly ascending' ((@($accountGrid.Rows|ForEach-Object {$_.Tag.id}) -join ',') -eq 'd,a,b,c,r-low,r-mid,r-high,r-unknown')
Assert-Grid 'default header indicates weekly descending' ($accountGrid.SortedColumn.Index -eq 2 -and $accountGrid.SortOrder -eq 'Descending')
$reference=New-Object Windows.Forms.DataGridView
$reference.AllowUserToAddRows=$false
foreach($column in $accountGrid.Columns){[void]$reference.Columns.Add($column.Name,$column.HeaderText)}
function Assert-NativeOrder($Name,$Column,$Direction){
    $reference.Rows.Clear()
    foreach($row in $accountGrid.Rows){
        if(-not $row.Tag.active -and -not $row.Tag.reserve){[void]$reference.Rows.Add([object[]]@($row.Cells|ForEach-Object {$_.Value}))}
    }
    $reference.Sort($reference.Columns[$Column],$Direction)
    $expected=@($reference.Rows|ForEach-Object {($_.Cells|ForEach-Object {$_.Value}) -join '|'}) -join "`n"
    $actual=@($accountGrid.Rows|Where-Object {-not $_.Tag.active -and -not $_.Tag.reserve}|ForEach-Object {($_.Cells|ForEach-Object {$_.Value}) -join '|'}) -join "`n"
    Assert-Grid $Name ($expected -eq $actual -and $accountGrid.Rows[0].Tag.active)
}
foreach($column in 0..4){
    foreach($direction in @([ComponentModel.ListSortDirection]::Ascending,[ComponentModel.ListSortDirection]::Descending)){
        $accountGrid.Sort($accountGrid.Columns[$column],$direction)
        Assert-NativeOrder ("column $column $direction keeps active first and native order for others") $column $direction
        Assert-Grid ("column $column $direction keeps reserves at bottom in independent weekly order") ((@($accountGrid.Rows|Select-Object -Last 4|ForEach-Object {$_.Tag.id}) -join ',') -eq 'r-low,r-mid,r-high,r-unknown')
    }
}
$accountGrid.Sort($accountGrid.Columns[2],[ComponentModel.ListSortDirection]::Descending)
$script:accounts[0].usage.secondary.remainingPercent=99
[array]::Reverse($script:accounts);Render-Accounts
Assert-Grid 'quota refresh retains chosen column and descending arrow' ($accountGrid.SortedColumn.Index -eq 2 -and $accountGrid.SortOrder -eq 'Descending' -and $accountGrid.Columns[2].HeaderCell.SortGlyphDirection -eq 'Descending')
Assert-NativeOrder 'refreshed values follow the same sort with active pinned' 2 ([ComponentModel.ListSortDirection]::Descending)
foreach($a in $script:accounts){$a.active=$a.id -eq 'b'};Render-Accounts
Assert-Grid 'switching active account repins correct identity after refresh' ($accountGrid.Rows[0].Tag.id -eq 'b')
Assert-NativeOrder 'previous active account returns to selected ordinary order' 2 ([ComponentModel.ListSortDirection]::Descending)
foreach($a in $script:accounts|Where-Object {$_.id -in @('b','c')}){$a.email='shared@test'}
foreach($direction in @([ComponentModel.ListSortDirection]::Ascending,[ComponentModel.ListSortDirection]::Descending)){
    Render-Accounts;$accountGrid.Sort($accountGrid.Columns[0],$direction)
    Assert-Grid ("duplicate emails still pin the actual active account $direction") ($accountGrid.Rows[0].Tag.id -eq 'b')
}
foreach($a in $script:accounts|Where-Object {$_.id -in @('a','c','d')}){$a.usage.secondary.remainingPercent=@{a=100;c=9;d=50}[$a.id]}
Render-Accounts;$accountGrid.Sort($accountGrid.Columns[2],[ComponentModel.ListSortDirection]::Descending)
Assert-Grid 'ordinary weekly descending uses numeric percentages including 100 and 9' ((@($accountGrid.Rows|Where-Object {-not $_.Tag.reserve}|ForEach-Object {$_.Tag.id}) -join ',') -eq 'b,a,d,c')
$accountGrid.Sort($accountGrid.Columns[2],[ComponentModel.ListSortDirection]::Ascending)
Assert-Grid 'ordinary weekly ascending changes no reserve ordering' ((@($accountGrid.Rows|ForEach-Object {$_.Tag.id}) -join ',') -eq 'b,c,d,a,r-low,r-mid,r-high,r-unknown')
foreach($a in $script:accounts){$a.active=$a.id -eq 'r-mid'};Render-Accounts
Assert-Grid 'currently active reserve still takes precedence over bottom grouping' ($accountGrid.Rows[0].Tag.id -eq 'r-mid' -and (@($accountGrid.Rows|Select-Object -Last 3|ForEach-Object {$_.Tag.id}) -join ',') -eq 'r-low,r-high,r-unknown')
foreach($a in $script:accounts){$a.active=$a.id -eq 'b'};Render-Accounts
$accountGrid.Sort($accountGrid.Columns[0],[ComponentModel.ListSortDirection]::Descending)
$script:accounts=@();Render-Accounts
Assert-Grid 'empty refresh preserves sort state without errors' ($accountGrid.Rows.Count -eq 0 -and $accountGrid.SortedColumn.Index -eq 0)
$script:accounts=@((New-AccountRow 'only' 'only@test' $true 50 50 2000000000));Render-Accounts
Assert-Grid 'single-account refresh remains pinned' ($accountGrid.Rows.Count -eq 1 -and $accountGrid.Rows[0].Tag.id -eq 'only')
$reference.Dispose();Write-Host "Passed $script:passed; failed 0";$form.Hide()
'@
try{
    $null=New-Item -ItemType Directory $tmp -Force
    Copy-Item (Join-Path $root 'lib') (Join-Path $tmp 'lib') -Recurse
    $text=Get-Content (Join-Path $root 'dashboard.ps1') -Raw -Encoding UTF8
    $text=$text.Replace('Refresh-UI;$script:timer=New-Object', $fixture+"`nRefresh-UI;`$script:timer=New-Object")
    [IO.File]::WriteAllText((Join-Path $tmp 'dashboard.ps1'),$text,(New-Object Text.UTF8Encoding($true)))
    & powershell -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $tmp 'dashboard.ps1') -SmokeTest
    if($LASTEXITCODE -ne 0){throw 'Account grid regression failed'}
}finally{Remove-TestDirectory $tmp}
