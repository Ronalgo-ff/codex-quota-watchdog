# Real Windows named-pipe framing and desktop adapter, against an isolated fake desktop.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('desktop-pipe-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$name='codex-app-tools-quota-test-'+[guid]::NewGuid().ToString('N')
$server=Join-Path $tmp 'server.ps1'
$source=@'
param($PipeName,$Root)
$ErrorActionPreference='Stop'
function Read-Exact($s,$n){$b=New-Object byte[] $n;$p=0;while($p-lt$n){$r=$s.Read($b,$p,$n-$p);if($r-eq 0){throw 'closed'};$p+=$r};return ,$b}
for($i=0;$i-lt 6;$i++){
 $s=New-Object IO.Pipes.NamedPipeServerStream($PipeName,[IO.Pipes.PipeDirection]::InOut)
 try{
  Set-Content (Join-Path $Root 'ready') 'ready'
  $s.WaitForConnection()
  $n=[BitConverter]::ToInt32((Read-Exact $s 4),0)
  $r=[Text.Encoding]::UTF8.GetString((Read-Exact $s $n))|ConvertFrom-Json
  if($r.method-eq 'tools/list'){$result=@{tools=@(@{namespace='codex_app';name='send_message_to_thread'})}}
  else{
   Add-Content (Join-Path $Root 'calls.jsonl') ($r.params|ConvertTo-Json -Depth 12 -Compress) -Encoding UTF8
   $payload=if($r.params.tool-eq 'send_message_to_thread'){@{status='sent';threadId=$r.params.arguments.threadId}}else{@{thread=@{status=@{type='idle'};updatedAt=1790530000};turns=@(@{id='t1';status='completed';error=$null;items=@(@{type='userMessage';content=@(@{type='text';text='总结项目'})},@{type='agentMessage';phase='final_answer';text='任务尚未完成。'})})}}
   $result=@{success=$true;contentItems=@(@{type='inputText';text=($payload|ConvertTo-Json -Depth 12 -Compress)})}
  }
  $b=[Text.Encoding]::UTF8.GetBytes((@{id=$r.id;jsonrpc='2.0';result=$result}|ConvertTo-Json -Depth 15 -Compress))
  $h=[BitConverter]::GetBytes($b.Length);$s.Write($h,0,4)
  # Fragment response mid UTF-8 sequence, just like real stream reads can do.
  for($offset=0;$offset-lt$b.Length;$offset+=7){$s.Write($b,$offset,[Math]::Min(7,$b.Length-$offset));$s.Flush()}
 }finally{$s.Dispose()}
}
'@
[IO.File]::WriteAllText($server,$source,(New-Object Text.UTF8Encoding($true)))
$child=$null;$pass=0;$fail=0
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
 $child=Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PipeName "{1}" -Root "{2}"' -f $server,$name,$tmp) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $tmp 'server.err')
 $deadline=(Get-Date).AddSeconds(5);while(-not(Test-Path (Join-Path $tmp 'ready')) -and (Get-Date)-lt$deadline){Start-Sleep -Milliseconds 50}
 $script:TestPipe='\\.\pipe\'+$name
 # Exercise real discovery, including OS enumeration and tools/list. Restrict
 # candidates to this fixture so a failing test can never call the real desktop.
 $script:RealPipeDiscovery=${function:Get-DesktopPipePaths}
 function Get-DesktopPipePaths {return @(& $script:RealPipeDiscovery | Where-Object {$_ -eq $script:TestPipe})}
 $env:CODEX_APP_TOOLS_PIPE_PATH=$null
 $script:DesktopPipe=$null
 $Script:Config.DesktopCallerThreadId='audit-test-context'
 $v=Get-TurnView 'test-thread'
 Check 'new app-tools pipe discovered without inherited environment or cached route' ($script:DesktopPipe -eq $script:TestPipe)
 Check 'fragmented native pipe response decoded correctly' ($v.Outcome-eq 'finished' -and $v.Final-eq '任务尚未完成。')
 $reply=Invoke-DesktopTool 'send_message_to_thread' @{threadId='test-thread';hostId='local';prompt='继续'}
 Check 'native desktop send receives structured acknowledgement' ($reply.status-eq 'sent')
 $calls=@(Get-Content (Join-Path $tmp 'calls.jsonl') -Encoding UTF8|ForEach-Object {$_|ConvertFrom-Json})
 Check 'exact Unicode continuation and host are preserved' ($calls[1].arguments.prompt-eq '继续' -and $calls[1].arguments.hostId-eq 'local')
 Check 'caller context and tool namespace correct' ($calls[1].threadId-eq 'audit-test-context' -and $calls[1].namespace-eq 'codex_app')
 Check 'no model or reasoning override is sent' (-not $calls[1].arguments.PSObject.Properties['model'] -and -not $calls[1].arguments.PSObject.Properties['thinking'])
}finally{
 if($child -and -not $child.HasExited){Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue}
 Remove-TestDirectory $tmp
}
Write-Host "通过 $pass 项，失败 $fail 项"
exit $(if($fail){1}else{0})
