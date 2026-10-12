' Hidden Windows launcher for the tray UI; start.cmd remains the console fallback.
Set fs = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fs.GetParentFolderName(WScript.ScriptFullName)
pwsh = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fs.FileExists(pwsh) Then
    pwsh = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
End If
q = Chr(34)
command = q & pwsh & q & " -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " & q & root & "\tray.ps1" & q
sh.Run command, 0, False
