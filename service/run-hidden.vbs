' Windowless PowerShell launcher. powershell.exe is a console app, so even
' -WindowStyle Hidden flashes a console when Task Scheduler starts it in the
' interactive session. wscript.exe has no console, and Run(..., 0) starts the
' child with SW_HIDE, so no window ever appears.
' Usage: wscript.exe //B //NoLogo run-hidden.vbs <script.ps1> [args...]
' Waits for PowerShell and propagates its exit code so Task Scheduler still
' sees the task as Running while the script runs and gets the real result.
Option Explicit
Dim shell, command, i, rc
Set shell = CreateObject("WScript.Shell")
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
    command = command & " """ & WScript.Arguments(i) & """"
Next
rc = shell.Run(command, 0, True)
WScript.Quit rc
