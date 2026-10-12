<# 本机初始化与只读健康检查。不会切号、发送消息或消耗额度。 #>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$NoShortcut,
    [switch]$RefreshAccounts,
    [string]$CallerThreadId = $env:CODEX_THREAD_ID,
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

function Get-SetupProperty($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Invoke-SetupRead([string]$Endpoint, [string]$Command) {
    if ($Command -notin @('get_app_info','list_accounts')) { throw '初始化只允许读取接口' }
    $options = @{}
    if (([uri]$Endpoint).IsLoopback -and (Get-Command Invoke-RestMethod).Parameters.ContainsKey('NoProxy')) { $options.NoProxy = $true }
    try {
        $reply = Invoke-RestMethod -Uri $Endpoint -Method Post -ContentType 'application/json' `
            -Body (@{command=$Command;args=@{}} | ConvertTo-Json -Compress) -TimeoutSec 8 @options
        if (-not $reply.ok) { throw [string]$reply.error }
        return $reply.result
    } catch {
        throw "无法读取 Codex Switch 本机管理接口。请打开 Switch → 设置 → 网络与同步 → 网页版监听端口（18080）。官方登录可以继续使用。接口：$Endpoint；详情：$($_.Exception.Message)"
    }
}

function Get-SetupCaller([string]$HomePath, [string]$PreferredId) {
    if ($PreferredId -match '^[0-9a-f-]{36}$') { return $PreferredId }
    $sessionRoot = Join-Path $HomePath 'sessions'
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
        $reader = $null
        try {
            $reader = New-Object IO.StreamReader([IO.File]::Open($file.FullName,'Open','Read','ReadWrite'),[Text.Encoding]::UTF8)
            $record = $reader.ReadLine() | ConvertFrom-Json
            if ($record.type -eq 'session_meta' -and $record.payload.source -eq 'vscode' -and $record.payload.originator -eq 'Codex Desktop') { return [string]$record.payload.id }
        } catch { } finally { if ($reader) { $reader.Dispose() } }
    }
    throw '没有找到本机 Codex 桌面聊天。请先在 Codex 桌面打开一条本地聊天。'
}

function Test-SetupAccounts($Accounts, [int]$Expected) {
    $items = @($Accounts)
    if ($items.Count -eq 0 -or @($items | Where-Object active).Count -ne 1) { throw 'Switch 必须有账号，并有且仅有一个当前账号。' }
    if (@($items | Where-Object { -not (Get-SetupProperty $_ 'id') }).Count -gt 0 -or @($items.id | Select-Object -Unique).Count -ne $items.Count) { throw 'Switch 返回的账号身份不完整，暂不启动。' }
    if ($Expected -gt 0 -and $items.Count -ne $Expected) { throw "账号数量发生变化（配置 $Expected，当前 $($items.Count)）。确认账号集合后运行 setup.ps1 -RefreshAccounts，保留现有去重记录。" }
}

if ($LibraryOnly) { return }

$localPath = Join-Path $Here 'rules.local.json'
$local = $null
if (Test-Path -LiteralPath $localPath) { $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json }
$endpoint = [string](Get-SetupProperty $local 'CswEndpoint')
if (-not $endpoint) {
    $port = 18080
    $switchSettingsFile = Join-Path $env:APPDATA 'dev.codex.switch\settings.json'
    if (Test-Path -LiteralPath $switchSettingsFile) {
        $switchSettings = Get-Content -LiteralPath $switchSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedPort = Get-SetupProperty $switchSettings 'webProxyPort'
        if ($savedPort -and [int]$savedPort -gt 0 -and [int]$savedPort -le 65535) { $port = [int]$savedPort }
    }
    $endpoint = "http://127.0.0.1:$port/__codex_switch__/api/invoke"
}
if (-not ([uri]$endpoint).IsLoopback) { throw '本机适配仅支持 localhost 管理接口。' }
$info = Invoke-SetupRead $endpoint 'get_app_info'
$accounts = @(Invoke-SetupRead $endpoint 'list_accounts')
$expected = 0
if (-not $RefreshAccounts) { $expected = [int](Get-SetupProperty $local 'ExpectedAccounts') }
Test-SetupAccounts $accounts $expected
$codexHomePath = [string](Get-SetupProperty $local 'CodexHome')
if (-not $codexHomePath) { $codexHomePath = [string](Get-SetupProperty $info 'codexHome') }
if (-not $codexHomePath) { $codexHomePath = Join-Path $env:USERPROFILE '.codex' }
if (-not (Test-Path -LiteralPath (Join-Path $codexHomePath 'sessions'))) { throw "Codex 会话目录不存在：$codexHomePath" }
$preferredCaller = [string](Get-SetupProperty $local 'DesktopCallerThreadId')
if ($PSBoundParameters.ContainsKey('CallerThreadId') -or -not $preferredCaller) { $preferredCaller = $CallerThreadId }
$caller = Get-SetupCaller $codexHomePath $preferredCaller
. (Join-Path $Here 'lib\desktop.ps1')
$Script:Config = @{DesktopCallerThreadId=$caller}
$desktop = Invoke-DesktopTool 'read_thread' @{threadId=$caller;turnLimit=1}
if ((Get-SetupProperty (Get-SetupProperty $desktop 'thread') 'id') -ne $caller) { throw 'Codex 桌面没有确认本机聊天身份，暂不启动。' }

if (-not $CheckOnly) {
    # Preserve intentional local overrides; only initialize discovered machine keys.
    $values = [ordered]@{}
    if ($local) { foreach ($property in $local.PSObject.Properties) { $values[$property.Name] = $property.Value } }
    $values['CswEndpoint'] = $endpoint
    $values['CodexHome'] = $codexHomePath
    $values['SessionRoot'] = Join-Path $codexHomePath 'sessions'
    $values['ExpectedAccounts'] = $accounts.Count
    $values['DesktopCallerThreadId'] = $caller
    $legacyScheduler = Join-Path $env:LOCALAPPDATA 'CodexSwitchQuotaScheduler\CodexSwitchQuotaScheduler.ps1'
    if (-not $values.Contains('QuotaSchedulerScript') -or $values['QuotaSchedulerScript'] -eq $legacyScheduler) { $values['QuotaSchedulerScript'] = Join-Path $Here 'scheduler.ps1' }
    $json = $values | ConvertTo-Json -Depth 6
    $existingText = if (Test-Path -LiteralPath $localPath) { [IO.File]::ReadAllText($localPath) } else { '' }
    if ($existingText -ne $json) {
        $tempPath = $localPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tempPath,$json,(New-Object Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tempPath -Destination $localPath -Force
    }
    foreach ($name in @('state','logs')) { $null = New-Item -ItemType Directory -Path (Join-Path $Here $name) -Force }
    if (-not $NoShortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 额度看护.lnk'))
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments = '"' + (Join-Path $Here 'start-tray.vbs') + '"'
        $shortcut.WorkingDirectory = $Here
        $shortcut.Description = 'Codex 额度看护：打开菜单，选择正常模式即可运行'
        $iconPath = Join-Path $Here 'assets\codex-quota.ico'
        $shortcut.IconLocation = if (Test-Path -LiteralPath $iconPath) { $iconPath + ',0' } else { (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',21' }
        $shortcut.Save()
    }
}
[pscustomobject]@{ready=$true;switchVersion=$info.version;accounts=$accounts.Count;activeAccounts=@($accounts | Where-Object active).Count;endpoint=$endpoint;desktop='ok';configuration=$localPath}
