@echo off &setlocal

call :init_TermPid
%TermPid%
set "pid=%errorlevel%"
echo Term PID:  %pid%

call :init_Fade
%Fade% 0 1 100 1 %pid%
%Fade% 100 -1 0 1 %pid%

goto :eof

::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:init_TermPid
setlocal DisableDelayedExpansion
:: prefer PowerShell Core if installed
for %%i in ("pwsh.exe") do if "%%~$PATH:i"=="" (set "ps=powershell") else set "ps=pwsh"

:: - BRIEF -
::  Get the process ID of the terminal app which is connected to the batch process.
::   The PID is returned as errorlevel value.
::   NOTE: Only console host and Windows Terminal are supported.
:: - SYNTAX -
::  %TermPid%
:: - EXAMPLES -
::  Get the process ID of the terminal app:
::    %TermPid%
::    echo PID: %errorlevel%
set TermPid=^
%=% %ps%.exe -nop -ep Bypass -c ^"^
%===% Add-Type '^
%=====% using System;^
%=====% using System.Diagnostics;^
%=====% using System.Runtime.ConstrainedExecution;^
%=====% using System.Runtime.InteropServices;^
%=====% public static class WinTerm {^
%=======% private static class NativeMethods {^
%=========% [DllImport(\"kernel32.dll\")]^
%=========% internal static extern int CloseHandle(IntPtr Hndl);^
%=========% [DllImport(\"kernelbase.dll\")]^
%=========% internal static extern int CompareObjectHandles(IntPtr hFirst, IntPtr hSecond);^
%=========% [DllImport(\"kernel32.dll\")]^
%=========% internal static extern int DuplicateHandle(IntPtr SrcProcHndl, IntPtr SrcHndl, IntPtr TrgtProcHndl, out IntPtr TrgtHndl, int Acc, int Inherit, int Opts);^
%=========% [DllImport(\"kernel32.dll\")]^
%=========% internal static extern IntPtr GetConsoleWindow();^
%=========% [DllImport(\"kernel32.dll\")]^
%=========% internal static extern IntPtr GetCurrentProcess();^
%=========% [DllImport(\"user32.dll\")]^
%=========% internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint procId);^
%=========% [DllImport(\"ntdll.dll\")]^
%=========% internal static extern int NtQuerySystemInformation(int SysInfClass, IntPtr SysInf, int SysInfLen, out int RetLen);^
%=========% [DllImport(\"kernel32.dll\")]^
%=========% internal static extern IntPtr OpenProcess(int Acc, int Inherit, uint ProcId);^
%=========% [DllImport(\"user32.dll\")]^
%=========% internal static extern IntPtr SendMessageW(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);^
%=======% }^
%=======% private class SafeRes : CriticalFinalizerObject, IDisposable {^
%=========% internal enum ResType { MemoryPointer, Handle }^
%=========% private IntPtr raw = IntPtr.Zero;^
%=========% private readonly ResType resourceType = ResType.MemoryPointer;^
%=========% internal IntPtr Raw { get { return raw; } }^
%=========% internal bool IsInvalid { get { return raw == IntPtr.Zero ^^^|^^^| raw == new IntPtr(-1); } }^
%=========% internal SafeRes(IntPtr raw, ResType resourceType) {^
%===========% this.raw = raw;^
%===========% this.resourceType = resourceType;^
%=========% }^
%=========% ~SafeRes() { Dispose(false); }^
%=========% public void Dispose() {^
%===========% Dispose(true);^
%===========% GC.SuppressFinalize(this);^
%=========% }^
%=========% protected virtual void Dispose(bool disposing) {^
%===========% if (IsInvalid) { return; }^
%===========% if (resourceType == ResType.MemoryPointer) {^
%=============% Marshal.FreeHGlobal(raw);^
%=============% raw = IntPtr.Zero;^
%=============% return;^
%===========% }^
%===========% if ((NativeMethods.CloseHandle(raw) == 0) == false) { raw = new IntPtr(-1); }^
%=========% }^
%=======% }^
%=======% [StructLayout(LayoutKind.Sequential)]^
%=======% private struct SystemHandle {^
%=========% internal readonly uint ProcId;^
%=========% internal readonly byte ObjTypeNum;^
%=========% internal readonly byte Flgs;^
%=========% internal readonly ushort Handle;^
%=========% internal readonly IntPtr pObj;^
%=========% internal readonly uint Acc;^
%=======% }^
%=======% private static uint FindWTCallback(uint shellPid, uint termPid) {^
%=========% const int PROCESS_DUP_HANDLE = 0x0040,^
%===================% PROCESS_QUERY_LIMITED_INFORMATION = 0x1000,^
%===================% STATUS_INFO_LENGTH_MISMATCH = -1073741820,^
%===================% SystemHandleInformation = 16;^
%=========% int status,^
%=============% infSize = 0x10000;^
%=========% using (SafeRes sHTerm = new SafeRes(NativeMethods.OpenProcess(PROCESS_DUP_HANDLE, 0, termPid), SafeRes.ResType.Handle)) {^
%===========% if (sHTerm.IsInvalid) { return 0; }^
%===========% using (SafeRes sHShell = new SafeRes(NativeMethods.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, shellPid), SafeRes.ResType.Handle)) {^
%=============% if (sHShell.IsInvalid) { return 0; }^
%=============% IntPtr pSysHndlInf = Marshal.AllocHGlobal(infSize);^
%=============% int len;^
%=============% while ((status = NativeMethods.NtQuerySystemInformation(SystemHandleInformation, pSysHndlInf, infSize, out len)) == STATUS_INFO_LENGTH_MISMATCH) {^
%===============% Marshal.FreeHGlobal(pSysHndlInf);^
%===============% pSysHndlInf = Marshal.AllocHGlobal(infSize = len);^
%=============% }^
%=============% using (SafeRes sPSysHndlInf = new SafeRes(pSysHndlInf, SafeRes.ResType.MemoryPointer)) {^
%===============% if (status ^^^< 0) { return 0; }^
%===============% uint pid = 0;^
%===============% IntPtr hCur = NativeMethods.GetCurrentProcess();^
%===============% int sysHndlSize = Marshal.SizeOf(typeof(SystemHandle));^
%===============% for (IntPtr pSysHndl = (IntPtr)((long)sPSysHndlInf.Raw + IntPtr.Size), pEnd = (IntPtr)((long)pSysHndl + Marshal.ReadInt32(sPSysHndlInf.Raw) * sysHndlSize);^
%====================% (pSysHndl == pEnd) == false;^
%====================% pSysHndl = (IntPtr)((long)pSysHndl + sysHndlSize)) {^
%=================% SystemHandle sysHndl = (SystemHandle)Marshal.PtrToStructure(pSysHndl, typeof(SystemHandle));^
%=================% IntPtr hDup;^
%=================% if ((sysHndl.ProcId == termPid) == false ^^^|^^^|^
%=====================% NativeMethods.DuplicateHandle(sHTerm.Raw, (IntPtr)sysHndl.Handle, hCur, out hDup, PROCESS_QUERY_LIMITED_INFORMATION, 0, 0) == 0) {^
%===================% continue;^
%=================% }^
%=================% using (SafeRes sHDup = new SafeRes(hDup, SafeRes.ResType.Handle)) {^
%===================% if ((NativeMethods.CompareObjectHandles(sHDup.Raw, sHShell.Raw) == 0) == false) {^
%=====================% pid = termPid;^
%=====================% break;^
%===================% }^
%=================% }^
%===============% }^
%===============% return pid;^
%=============% }^
%===========% }^
%=========% }^
%=======% }^
%=======% private static readonly IntPtr conWnd = NativeMethods.GetConsoleWindow();^
%=======% private static Process GetTermProc() {^
%=========% const int WM_GETICON = 0x007F;^
%=========% uint shellPid;^
%=========% if (NativeMethods.GetWindowThreadProcessId(conWnd, out shellPid) == 0) { return null; }^
%=========% if ((NativeMethods.SendMessageW(conWnd, WM_GETICON, IntPtr.Zero, IntPtr.Zero) == IntPtr.Zero) == false) {^
%===========% return Process.GetProcessById((int)shellPid);^
%=========% }^
%=========% foreach (Process termProc in Process.GetProcessesByName(\"WindowsTerminal\")) {^
%===========% uint termPid = FindWTCallback(shellPid, (uint)termProc.Id);^
%===========% if ((termPid == 0) == false) { return termProc; }^
%=========% }^
%=========% return null;^
%=======% }^
%=======% private static readonly Process termProc = GetTermProc();^
%=======% public static Process TermProc { get { return termProc; } }^
%=====% }^
%===% ';^
%===% $termProc = [WinTerm]::TermProc;^
%===% exit $(if ($termProc) { $termProc.Id } else { 0 });^
%=% ^"

endlocal &set "TermPid=%TermPid%"
exit /b
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:init_Fade
setlocal DisableDelayedExpansion
:: prefer PowerShell Core if installed
for %%i in ("pwsh.exe") do if "%%~$PATH:i"=="" (set "ps=powershell") else set "ps=pwsh"

:: - BRIEF -
::  Use alpha blending to fade the window in or out.
:: - SYNTAX -
::  %Fade% start step end delay [pid]
::    start  percentage of transparency to begin with where 0 is for opaque,
::            and 100 is for limpid
::    step   number of percents the current value is advanced in each iteration
::    end    percentage of transparency to end with
::    delay  milliseconds to wait in each iteration to control the speed
::    pid    (optional) ID of a process whose main window is to be faded
::   To immediately set the window to a certain transparency, specify the same
::    value for both the start and end arguments.
:: - EXAMPLES -
::  Fade out the window to full transparency:
::    %Fade% 0 1 100 1
::  Fade in the window to full opacity:
::    %Fade% 100 -1 0 1
::  Instantly set window transprency to 30%:
::    %Fade% 30 0 30 0
set Fade=for %%# in (1 2) do if %%#==2 (for /f "tokens=1-5" %%- in ("^^!args^^! x x x x x") do^
%=% %ps%.exe -nop -ep Bypass -c ^"^
%===% $w=Add-Type -Name WAPI -PassThru -MemberDefinition '^
%=====% [DllImport(\"kernel32.dll\")]^
%=======% public static extern IntPtr GetConsoleWindow();^
%=====% [DllImport(\"user32.dll\")]^
%=======% public static extern int GetWindowLongW(IntPtr wnd, int idx);^
%=====% [DllImport(\"user32.dll\")]^
%=======% public static extern void SetWindowLongW(IntPtr wnd, int idx, int newLong);^
%=====% [DllImport(\"user32.dll\")]^
%=======% public static extern int SetLayeredWindowAttributes(IntPtr wnd, int color, int alpha, int flags);^
%===% ';^
%===% $start=0; $step=0; $end=0; $delay=0; $tpid=0;^
%===% if (-not [Int32]::TryParse('%%~-', [ref]$start) -or^
%=====% -not [Int32]::TryParse('%%~.', [ref]$step) -or^
%=====% -not [Int32]::TryParse('%%~/', [ref]$end) -or^
%=====% -not [Int32]::TryParse('%%~0', [ref]$delay) -or^
%=====% $start -lt 0 -or $start -gt 100 -or^
%=====% $end -lt 0 -or $end -gt 100 -or^
%=====% $delay -lt 0^
%===% ) {exit 1}^
%===% $GWL_EXSTYLE=-20;^
%===% $WS_EX_LAYERED=0x80000;^
%===% if ([Int32]::TryParse('%%~1', [ref]$tpid)) {^
%=====% $wnd=(gps -id $tpid -ea SilentlyContinue).MainWindowHandle;^
%===% } else {^
%=====% $wnd=$w::GetConsoleWindow();^
%===% }^
%===   legacy console and Windows Terminal need to be turned into a layered window   =% ^
%===% $w::SetWindowLongW($wnd, $GWL_EXSTYLE, $w::GetWindowLongW($wnd, $GWL_EXSTYLE) -bOr $WS_EX_LAYERED);^
%===% $LWA_ALPHA=2;^
%===% if (($start -lt $end) -and ($step -gt 0)) { %= fade out =%^
%=====% for ($i=$start; $i -lt $end; $i+=$step) {^
%=======% $null=$w::SetLayeredWindowAttributes($wnd, 0, [math]::Round(255 - 2.55 * $i), $LWA_ALPHA);^
%=======% [Threading.Thread]::Sleep($delay);^
%=====% }^
%===% } elseif (($start -gt $end) -and ($step -lt 0)) { %= fade in =%^
%=====% for ($i=$start; $i -gt $end; $i+=$step) {^
%=======% $null=$w::SetLayeredWindowAttributes($wnd, 0, [math]::Round(255 - 2.55 * $i), $LWA_ALPHA);^
%=======% [Threading.Thread]::Sleep($delay);^
%=====% }^
%===% } elseif ($start -ne $end) {exit 1} %= reject remaining inconclusive values =%^
%===   always use the 'end' value even if the distance between 'start' and 'end' is not a multiple of 'step'   =% ^
%===% exit [int]($w::SetLayeredWindowAttributes($wnd, 0, [math]::Round(255 - 2.55 * $end), $LWA_ALPHA) -eq 0);^
%=% ^" ^&endlocal) else setlocal EnableDelayedExpansion ^&set args=

endlocal &set "Fade=%Fade%"
if !!# neq # set "Fade=%Fade:^^=%"
exit /b
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
