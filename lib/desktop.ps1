# Local desktop transport. Uses the protocol shipped in codex-app-tools/server.mjs.
# No external CLI writer, no window focus, and no queue that waits for navigation.
function Read-DesktopBytes {
    param($Pipe, [int]$Count, [datetime]$Deadline)
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $task = $Pipe.ReadAsync($buffer, $offset, $Count - $offset)
        $ms = [int][Math]::Max(1, ($Deadline - (Get-Date)).TotalMilliseconds)
        if (-not $task.Wait($ms)) { throw 'Desktop pipe response timeout; delivery may be uncertain' }
        $n = $task.Result
        if ($n -eq 0) { throw 'Desktop pipe closed; delivery may be uncertain' }
        $offset += $n
    }
    return ,$buffer
}

function Invoke-DesktopRpc {
    param([string]$PipePath, [string]$Method, $Params, [int]$TimeoutSec = 15)
    $name = $PipePath -replace '^\\\\\.\\pipe\\', ''
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $name, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $requestId='quota-'+[guid]::NewGuid().ToString('N')
    $complete=$false
    try {
        $pipe.Connect(1000)
        $request = @{ id=$requestId; jsonrpc='2.0'; method=$Method; params=$Params } | ConvertTo-Json -Depth 15 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($request)
        $header = [BitConverter]::GetBytes([int]$bytes.Length)
        $pipe.Write($header,0,4); $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $length = [BitConverter]::ToInt32((Read-DesktopBytes $pipe 4 $deadline),0)
        if ($length -le 0 -or $length -gt 8MB) { throw 'Invalid desktop frame length' }
        $reply = [Text.Encoding]::UTF8.GetString((Read-DesktopBytes $pipe $length $deadline)) | ConvertFrom-Json
        if([string]$reply.id -ne $requestId){throw 'Desktop response id mismatch'}
        $complete=$true
        if ($reply.PSObject.Properties['error']) { throw $reply.error.message }
        return $reply.result
    } finally {
        # App keeps pending calls globally by JSON-RPC id. Cancel timed-out READS
        # on this same socket; a mutation may already have executed, so never replay it.
        if(-not $complete -and $pipe.IsConnected -and $Method -eq 'tools/call' -and $Params.tool -in @('list_threads','read_thread')){
            try{
                $cancel=[Text.Encoding]::UTF8.GetBytes((@{id=$requestId;jsonrpc='2.0';method='tools/cancel'}|ConvertTo-Json -Compress))
                $h=[BitConverter]::GetBytes($cancel.Length);$pipe.Write($h,0,4);$pipe.Write($cancel,0,$cancel.Length);$pipe.Flush()
            }catch{}
        }
        $pipe.Dispose()
    }
}

$script:DesktopPipe = $null
function Find-DesktopPipe {
    $paths = @($script:DesktopPipe, $env:CODEX_APP_TOOLS_PIPE_PATH)
    $paths += @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'codex-browser-use-' })
    foreach ($path in @($paths | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            $catalog = Invoke-DesktopRpc $path 'tools/list' @{threadStartKind='all'} 2
            if (@($catalog.tools | Where-Object { $_.namespace -eq 'codex_app' -and $_.name -eq 'send_message_to_thread' }).Count -eq 1) {
                $script:DesktopPipe = $path
                return $path
            }
        } catch { }
    }
    throw 'Codex 桌面通道不可用；保持看护，等待桌面恢复'
}

function Invoke-DesktopTool {
    param([string]$Tool, [hashtable]$Arguments = @{})
    if ($Tool -notin @('list_threads','read_thread','send_message_to_thread')) { throw 'Unsupported desktop operation' }
    $path = Find-DesktopPipe
    $caller = [string]$Script:Config.DesktopCallerThreadId
    if (-not $caller) { throw '缺少 DesktopCallerThreadId' }
    $timeout=if($Tool -eq 'list_threads'){5}else{20}
    # Never retry tools/call: a lost response is not proof of a rejected prompt.
    $r = Invoke-DesktopRpc $path 'tools/call' @{
        arguments=$Arguments; callerSource='codex'; callId=('autopilot-'+[guid]::NewGuid().ToString('N'))
        namespace='codex_app'; threadId=$caller; tool=$Tool; turnId=('autopilot-'+[guid]::NewGuid().ToString('N'))
    } $timeout
    $text = (@($r.contentItems | Where-Object {$_.type -eq 'inputText'} | ForEach-Object {$_.text}) -join "`n")
    if (-not $r.success) {
        $errorObject=New-Object InvalidOperationException($text)
        if($Tool -eq 'send_message_to_thread' -and $text.Trim() -eq 'App-server task is not ready: execution-config-loading'){
            # Verified local AppServerResumeNotReadyError: thrown before starting a turn.
            $errorObject.Data['QuotaPreDispatchRejected']=$true
        }
        throw $errorObject
    }
    try { return ($text | ConvertFrom-Json) } catch { throw "桌面返回非结构化结果：$text" }
}
