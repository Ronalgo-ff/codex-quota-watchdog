# Real named pipe: an unanswered read is cancelled; a mutation is never resent.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-autopilot.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'support\fixtures.ps1')
$tmp=Join-Path $env:TEMP ('quota-timeout-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tmp -Force
$source=@'
param($PipeName,$Output)
function Read-Frame($p){
 $h=New-Object byte[] 4;$offset=0
 while($offset -lt 4){$n=$p.Read($h,$offset,4-$offset);if($n -eq 0){return $null};$offset+=$n}
 $size=[BitConverter]::ToInt32($h,0);$b=New-Object byte[] $size;$offset=0
 while($offset -lt $size){$n=$p.Read($b,$offset,$size-$offset);if($n -eq 0){return $null};$offset+=$n}
 return ([Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json)
}
$p=New-Object IO.Pipes.NamedPipeServerStream($PipeName,[IO.Pipes.PipeDirection]::InOut)
try{
 Set-Content ($Output+'.ready') 'ready'
 $p.WaitForConnection();$first=Read-Frame $p;$next=Read-Frame $p
 @{first=$first;next=$next}|ConvertTo-Json -Depth 9|Set-Content $Output -Encoding UTF8
}finally{$p.Dispose()}
'@
$server=Join-Path $tmp 'server.ps1'
[IO.File]::WriteAllText($server,$source,(New-Object Text.UTF8Encoding($true)))
$pass=0;$fail=0;$child=$null;$ids=@()
function Check($Name,$OK){if($OK){$script:pass++;Write-Host "[PASS] $Name"}else{$script:fail++;Write-Host "[FAIL] $Name"}}
try{
 foreach($tool in @('list_threads','send_message_to_thread')){
  $name='quota-timeout-'+[guid]::NewGuid().ToString('N');$out=Join-Path $tmp ($tool+'.json')
  $child=Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PipeName "{1}" -Output "{2}"' -f $server,$name,$out) -WindowStyle Hidden -PassThru
  $deadline=(Get-Date).AddSeconds(5);while(-not (Test-Path ($out+'.ready')) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 50}
  $sw=[Diagnostics.Stopwatch]::StartNew();$errorText=''
  try{Invoke-DesktopRpc ('\\.\pipe\'+$name) 'tools/call' @{tool=$tool} 1|Out-Null}catch{$errorText=$_.Exception.Message}
  Check "$tool timeout remains bounded" ($errorText -match 'timeout' -and $sw.Elapsed.TotalSeconds -lt 4)
  if(-not $child.WaitForExit(4000)){throw 'Fake pipe did not exit'}
  $record=Get-Content $out -Raw|ConvertFrom-Json;$ids+=$record.first.id
  if($tool -eq 'list_threads'){
   Check 'timed-out read sends tools/cancel with exact request ID' ($record.next.method -eq 'tools/cancel' -and $record.next.id -eq $record.first.id)
  }else{
   Check 'uncertain mutation receives no retry or cancellation request' ($null -eq $record.next)
  }
 }
 Check 'different calls use unique request IDs' ($ids[0] -ne $ids[1])
}finally{
 if($child -and -not $child.HasExited){Stop-Process -Id $child.Id -Force}
 Remove-TestDirectory $tmp
}
Write-Host "Passed $pass; failed $fail"
exit $(if($fail){1}else{0})
