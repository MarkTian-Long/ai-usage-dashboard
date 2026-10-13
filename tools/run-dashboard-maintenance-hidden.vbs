Option Explicit

' WScript runs without a console; window style 0 also hides the child shell.
' Wait for the one-shot job so Task Scheduler receives its actual exit code.
Dim fso, root, scriptPath, shell, ps, quote, command, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
scriptPath = fso.BuildPath(root, "run-ai-usage-dashboard-maintenance.ps1")
Set shell = CreateObject("WScript.Shell")
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
quote = Chr(34)
command = quote & ps & quote & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & quote & scriptPath & quote
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
