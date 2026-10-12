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
    Check 'first launch discovers actual account count and local caller' ($local.ExpectedAccounts -eq 2 -and $local.DesktopCallerThreadId -eq $caller -and $result.ready)
    Check 'bootstrap discovers the local session directory' ($local.SessionRoot -eq (Join-Path $tmp 'home\sessions'))
    $local | Add-Member NoteProperty ResumeMessage 'custom-resume'
    [IO.File]::WriteAllText($configPath,($local | ConvertTo-Json),$enc)
    $null = & $setup -NoShortcut
    $before = (Get-FileHash $configPath).Hash
    Check 'existing intentional local overrides survive initialization' ((Get-Content $configPath -Raw | ConvertFrom-Json).ResumeMessage -eq 'custom-resume')
    $null = & $setup -CheckOnly -NoShortcut
    Check 'health check does not rewrite configuration' ((Get-FileHash $configPath).Hash -eq $before)
    Set-Content (Join-Path $tmp 'count.txt') '3'
    $threw = $false; try { $null = & $setup -NoShortcut } catch { $threw = $_.Exception.Message -match 'RefreshAccounts' }
    Check 'changed account count blocks startup and preserves baseline' ($threw -and (Get-FileHash $configPath).Hash -eq $before)
    $null = & $setup -NoShortcut -RefreshAccounts
    Check 'explicit account refresh updates baseline without clearing runtime state' ((Get-Content $configPath -Raw | ConvertFrom-Json).ExpectedAccounts -eq 3 -and (Test-Path (Join-Path $tmp 'state')))
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
