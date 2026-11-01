# Isolated machine bootstrap: fake read-only services, real configuration files.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp = Join-Path $env:TEMP ('quota-machine-setup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp,(Join-Path $tmp 'lib'),(Join-Path $tmp 'home\sessions') -Force
$pass = 0; $fail = 0
function Check($Name,$Ok) { if ($Ok) { $script:pass++; Write-Host "[PASS] $Name" } else { $script:fail++; Write-Host "[FAIL] $Name" } }
$enc = New-Object Text.UTF8Encoding($true)
$caller = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
try {
    Copy-Item (Join-Path $root 'lib\account-quota.ps1') (Join-Path $tmp 'lib\account-quota.ps1')
    $text = Get-Content (Join-Path $root 'setup.ps1') -Raw -Encoding UTF8
    $fixture = @'
function Invoke-SetupRead([string]$Endpoint,[string]$Command) {
    if ($Command -eq 'get_app_info') { return [pscustomobject]@{version='fixture';codexHome=(Join-Path $PSScriptRoot 'home')} }
    $count = [int](Get-Content (Join-Path $PSScriptRoot 'count.txt'))
    return @(1..$count | ForEach-Object { [pscustomobject]@{id="account-$_";active=($_ -eq 1)} })
}
'@
    $text = $text.Replace('if ($LibraryOnly) { return }', 'if ($LibraryOnly) { return }' + "`n" + $fixture)
    [IO.File]::WriteAllText((Join-Path $tmp 'setup.ps1'),$text,$enc)
    [IO.File]::WriteAllText((Join-Path $tmp 'lib\desktop.ps1'),@'
function Invoke-DesktopTool($Tool,$Arguments) { return [pscustomobject]@{thread=[pscustomobject]@{id=$Arguments.threadId}} }
'@,$enc)
    $setup = Join-Path $tmp 'setup.ps1'
    $configPath = Join-Path $tmp 'rules.local.json'
    Set-Content (Join-Path $tmp 'count.txt') '2'
    $result = & $setup -NoShortcut -CallerThreadId $caller
    $local = Get-Content $configPath -Raw | ConvertFrom-Json
    Check 'first launch discovers actual accounts without pinning a count' (-not $local.PSObject.Properties['ExpectedAccounts'] -and $result.accounts -eq 2 -and $local.DesktopCallerThreadId -eq $caller -and $result.ready)
    Check 'bootstrap discovers the local session directory' ($local.SessionRoot -eq (Join-Path $tmp 'home\sessions'))
    $local | Add-Member NoteProperty ResumeMessage 'custom-resume'
    [IO.File]::WriteAllText($configPath,($local | ConvertTo-Json),$enc)
    $null = & $setup -NoShortcut
    $before = (Get-FileHash $configPath).Hash
    Check 'existing intentional local overrides survive initialization' ((Get-Content $configPath -Raw | ConvertFrom-Json).ResumeMessage -eq 'custom-resume')
    $null = & $setup -CheckOnly -NoShortcut
    Check 'health check does not rewrite configuration' ((Get-FileHash $configPath).Hash -eq $before)
    Set-Content (Join-Path $tmp 'count.txt') '3'
    $result = & $setup -NoShortcut
    Check 'added accounts are discovered without blocking launch' ($result.ready -and $result.accounts -eq 3)
    $local = Get-Content $configPath -Raw | ConvertFrom-Json
    $local | Add-Member NoteProperty ExpectedAccounts 6 -Force
    [IO.File]::WriteAllText($configPath,($local | ConvertTo-Json),$enc)
    $pausePath=Join-Path $tmp 'state\manual-pause.json'
    $pause=@{active=$true;key='loop:预期 6 个账号，实际读取 7 个；等待完整数据';reportPath='old-report.json'}
    [IO.File]::WriteAllText($pausePath,($pause|ConvertTo-Json),$enc)
    [IO.File]::WriteAllText((Join-Path $tmp 'state\handled.json'),'preserved-state',$enc)
    $before=(Get-FileHash $configPath).Hash
    $result=& $setup -CheckOnly -NoShortcut
    Check 'health check tolerates legacy count without rewriting config or pause' ($result.ready -and (Get-FileHash $configPath).Hash -eq $before -and (Get-Content $pausePath -Raw|ConvertFrom-Json).active)
    Set-Content (Join-Path $tmp 'count.txt') '1'
    $result = & $setup -NoShortcut -RefreshAccounts
    $resolved=Get-Content $pausePath -Raw|ConvertFrom-Json
    Check 'removed accounts and legacy refresh argument are supported' ($result.ready -and $result.accounts -eq 1 -and -not (Get-Content $configPath -Raw|ConvertFrom-Json).PSObject.Properties['ExpectedAccounts'])
    Check 'only obsolete account-count pause is resolved with original evidence' (-not $resolved.active -and $resolved.action -eq 'account-sync-upgrade' -and $resolved.previous.key -eq $pause.key -and (Get-Content (Join-Path $tmp 'state\handled.json') -Raw).Trim() -eq 'preserved-state')
    $pause.key='switch:uncertain'
    [IO.File]::WriteAllText($pausePath,($pause|ConvertTo-Json),$enc)
    $before=(Get-FileHash $pausePath).Hash
    $null=& $setup -NoShortcut
    Check 'unrelated uncertain-operation pause remains unchanged' ((Get-FileHash $pausePath).Hash -eq $before)
    [IO.File]::WriteAllText($configPath,'{invalid',$enc)
    $threw = $false; try { $null = & $setup -NoShortcut } catch { $threw = $true }
    Check 'corrupt machine configuration fails instead of using another machine defaults' $threw
    . (Join-Path $root 'setup.ps1') -LibraryOnly
    $threw = $false; try { Invoke-SetupRead 'http://127.0.0.1:1' 'consume_account_quota' } catch { $threw = $_.Exception.Message -match '只允许读取' }
    Check 'setup refuses quota consumption and other mutating API operations' $threw
    $threw = $false; try { Test-SetupAccounts @([pscustomobject]@{id='a';active=$true},[pscustomobject]@{id='a';active=$false}) 2 } catch { $threw = $true }
    Check 'duplicate account identities are rejected' $threw
    $threw = $false; try { Test-SetupAccounts @([pscustomobject]@{id='a';active=$true},[pscustomobject]@{id='b';active=$true}) 2 } catch { $threw = $true }
    Check 'multiple active accounts are rejected' $threw
} finally { Remove-TestDirectory $tmp }
Write-Host "Passed $pass; failed $fail"
exit $(if ($fail) { 1 } else { 0 })
