Option Explicit

' Manual diagnostic launcher.  It derives the dashboard root from this file,
' so directory moves do not leave a hidden hard-coded path behind.
Dim fso, root, command, shell
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
command = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\start-ai-usage-dashboard-service.ps1"""
Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
