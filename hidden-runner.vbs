' hidden-runner.vbs - start a PowerShell script with NO window at all.
'
' Why this exists: on Windows 11 the default terminal host is Windows Terminal, which
' ignores "powershell -WindowStyle Hidden" - a scheduled task using that flag flashes a
' visible terminal window every time it fires. wscript is a GUI host (it has no console of
' its own) and WshShell.Run with window style 0 hides the child's console window, so the
' task runs completely invisibly.
'
' Arguments: the first is the script path; anything else is forwarded (values get quoted,
' switches starting with '-' do not).
'
' Usage:  wscript.exe hidden-runner.vbs "C:\path\to\script.ps1" -Config "C:\path\to\cfg.json"

Set sh = CreateObject("WScript.Shell")
If WScript.Arguments.Count = 0 Then
  WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  If Left(a, 1) = "-" Then
    cmd = cmd & " " & a
  Else
    cmd = cmd & " """ & a & """"
  End If
Next
sh.Run cmd, 0, False
