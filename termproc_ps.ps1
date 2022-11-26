<#
Copyright (c) 2022 Steffen Illhardt

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#>

# min. req.: PowerShell v.2

Add-Type @'
  using System;
  using System.Diagnostics;
  using System.Runtime.ConstrainedExecution;
  using System.Runtime.InteropServices;

  //# provides the TermProc property referencing the process of the terminal connected to the current console application
  public static class WinTerm {
    //# imports the used Windows API functions
    private static class NativeMethods {
      [DllImport("kernel32.dll")]
      internal static extern int CloseHandle(IntPtr Hndl);
      [DllImport("kernelbase.dll")]
      internal static extern int CompareObjectHandles(IntPtr hFirst, IntPtr hSecond);
      [DllImport("kernel32.dll")]
      internal static extern int DuplicateHandle(IntPtr SrcProcHndl, IntPtr SrcHndl, IntPtr TrgtProcHndl, out IntPtr TrgtHndl, int Acc, int Inherit, int Opts);
      [DllImport("kernel32.dll")]
      internal static extern IntPtr GetConsoleWindow();
      [DllImport("kernel32.dll")]
      internal static extern IntPtr GetCurrentProcess();
      [DllImport("user32.dll")]
      internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint procId);
      [DllImport("ntdll.dll")]
      internal static extern int NtQuerySystemInformation(int SysInfClass, IntPtr SysInf, int SysInfLen, out int RetLen);
      [DllImport("kernel32.dll")]
      internal static extern IntPtr OpenProcess(int Acc, int Inherit, uint ProcId);
      [DllImport("user32.dll")]
      internal static extern IntPtr SendMessageW(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    }

    //# owns an unmanaged resource
    //# the ctor qualifies a SafeRes object to manage either a pointer received from Marshal.AllocHGlobal(), or a handle
    private class SafeRes : CriticalFinalizerObject, IDisposable {
      //# resource type of a SafeRes object
      internal enum ResType { MemoryPointer, Handle }

      private IntPtr raw = IntPtr.Zero;
      private readonly ResType resourceType = ResType.MemoryPointer;

      internal IntPtr Raw { get { return raw; } }
      internal bool IsInvalid { get { return raw == IntPtr.Zero || raw == new IntPtr(-1); } }

      //# constructs a SafeRes object from an unmanaged resource specified by parameter raw
      //# the resource must be either a pointer received from Marshal.AllocHGlobal() (specify resourceType ResType.MemoryPointer),
      //# or a handle (specify resourceType ResType.Handle)
      internal SafeRes(IntPtr raw, ResType resourceType) {
        this.raw = raw;
        this.resourceType = resourceType;
      }

      ~SafeRes() { Dispose(false); }

      public void Dispose() {
        Dispose(true);
        GC.SuppressFinalize(this);
      }

      protected virtual void Dispose(bool disposing) {
        if (IsInvalid) { return; }
        if (resourceType == ResType.MemoryPointer) {
          Marshal.FreeHGlobal(raw);
          raw = IntPtr.Zero;
          return;
        }

        if (NativeMethods.CloseHandle(raw) != 0) { raw = new IntPtr(-1); }
      }
    }

    //# undocumented SYSTEM_HANDLE structure, SYSTEM_HANDLE_TABLE_ENTRY_INFO might be the actual name
    [StructLayout(LayoutKind.Sequential)]
    private struct SystemHandle {
      internal readonly uint ProcId; //# PID of the process the SYSTEM_HANDLE belongs to
      internal readonly byte ObjTypeNum;
      internal readonly byte Flgs;
      internal readonly ushort Handle; //# value representing an opened handle in the process
      internal readonly IntPtr pObj;
      internal readonly uint Acc;
    }

    //# Enumerate the opened handles in the WindowsTerminal.exe process specified by the process ID passed to termPid.
    //# Return termPid if one of the process handles points to the Shell process specified by the process ID passed to shellPid.
    //# Return 0 if the Shell process is not found.
    private static uint FindWTCallback(uint shellPid, uint termPid) {
      const int PROCESS_DUP_HANDLE = 0x0040, //# access right to duplicate handles
                PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, //# access right to retrieve certain process information
                STATUS_INFO_LENGTH_MISMATCH = -1073741820, //# NTSTATUS returned if we still didn't allocate enough memory
                SystemHandleInformation = 16; //# one of the SYSTEM_INFORMATION_CLASS values
      int status, //# retrieves the NTSTATUS return value
          infSize = 0x10000; //# initially allocated memory size for the SYSTEM_HANDLE_INFORMATION object
      //# open a handle to the WindowsTerminal process, granting permissions to duplicate handles
      using (SafeRes sHTerm = new SafeRes(NativeMethods.OpenProcess(PROCESS_DUP_HANDLE, 0, termPid), SafeRes.ResType.Handle)) {
        if (sHTerm.IsInvalid) { return 0; }
        //# open a handle to the Shell process
        using (SafeRes sHShell = new SafeRes(NativeMethods.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, shellPid), SafeRes.ResType.Handle)) {
          if (sHShell.IsInvalid) { return 0; }
          //# allocate some memory representing an undocumented SYSTEM_HANDLE_INFORMATION object, which can't be meaningfully declared in C# code
          IntPtr pSysHndlInf = Marshal.AllocHGlobal(infSize);
          //# try to get an array of all available SYSTEM_HANDLE objects, allocate more memory if necessary
          int len;
          while ((status = NativeMethods.NtQuerySystemInformation(SystemHandleInformation, pSysHndlInf, infSize, out len)) == STATUS_INFO_LENGTH_MISMATCH) {
            Marshal.FreeHGlobal(pSysHndlInf);
            pSysHndlInf = Marshal.AllocHGlobal(infSize = len);
          }

          using (SafeRes sPSysHndlInf = new SafeRes(pSysHndlInf, SafeRes.ResType.MemoryPointer)) {
            if (status < 0) { return 0; }
            uint pid = 0;
            IntPtr hCur = NativeMethods.GetCurrentProcess();
            int sysHndlSize = Marshal.SizeOf(typeof(SystemHandle));
            //# iterate over the array of SYSTEM_HANDLE objects, which begins at an offset of pointer size in the SYSTEM_HANDLE_INFORMATION object
            //# the number of SYSTEM_HANDLE objects is specified in the first 32 bits of the SYSTEM_HANDLE_INFORMATION object
            for (IntPtr pSysHndl = (IntPtr)((long)sPSysHndlInf.Raw + IntPtr.Size), pEnd = (IntPtr)((long)pSysHndl + Marshal.ReadInt32(sPSysHndlInf.Raw) * sysHndlSize);
                 pSysHndl != pEnd;
                 pSysHndl = (IntPtr)((long)pSysHndl + sysHndlSize)) {
              //# get one SYSTEM_HANDLE at a time
              SystemHandle sysHndl = (SystemHandle)Marshal.PtrToStructure(pSysHndl, typeof(SystemHandle));
              //# if the SYSTEM_HANDLE object doesn't belong to the WindowsTerminal process, or
              //# if duplicating its Handle member fails, continue with the next SYSTEM_HANDLE object
              //# the duplicated handle is necessary to get information about the object (e.g. the process) it points to
              IntPtr hDup;
              if (sysHndl.ProcId != termPid ||
                  NativeMethods.DuplicateHandle(sHTerm.Raw, (IntPtr)sysHndl.Handle, hCur, out hDup, PROCESS_QUERY_LIMITED_INFORMATION, 0, 0) == 0) {
                continue;
              }

              //# at this point duplicating succeeded and thus, sHDup is valid
              using (SafeRes sHDup = new SafeRes(hDup, SafeRes.ResType.Handle)) {
                //# compare the duplicated handle with the handle of our shell process
                //# if they point to the same kernel object, we are going to step out of the loop and return the PID of the WindowsTerminal process
                if (NativeMethods.CompareObjectHandles(sHDup.Raw, sHShell.Raw) != 0) {
                  pid = termPid;
                  break;
                }
              }
            }

            return pid;
          }
        }
      }
    }

    private static readonly IntPtr conWnd = NativeMethods.GetConsoleWindow();
    private static Process GetTermProc() {
      const int WM_GETICON = 0x007F;

      //# Get the ID of the Shell process that spawned the Conhost process.
      uint shellPid;
      if (NativeMethods.GetWindowThreadProcessId(conWnd, out shellPid) == 0) { return null; }
      //# We don't have a proper way to figure out to what terminal app the Shell process
      //# is connected on the local machine:
      //# https://#github.com/microsoft/terminal/issues/7434
      //# We're getting around this assuming we don't get an icon handle from the
      //# invisible Conhost window when the Shell is connected to Windows Terminal.
      if (NativeMethods.SendMessageW(conWnd, WM_GETICON, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero) {
        //# Conhost assumed: The Shell process' main window is the console window.
        //# (weird because the Shell has no own window, but it has always been like this)
        return Process.GetProcessById((int)shellPid);
      }

      //# We don't have a proper way to figure out which WindowsTerminal process
      //# is connected with the Shell process:
      //# https://#github.com/microsoft/terminal/issues/5694
      //# The assumption that the terminal is the parent process of the Shell process
      //# is gone with DefTerm (the Default Windows Terminal).
      //# Thus, I don't care about using more undocumented stuff:
      //# Get the process IDs of all WindowsTerminal processes and try to figure out
      //# which of them has a handle to the Shell process open.
      foreach (Process termProc in Process.GetProcessesByName("WindowsTerminal")) {
        uint termPid = FindWTCallback(shellPid, (uint)termProc.Id);
        if (termPid != 0) { return termProc; }
      }

      return null;
    }

    private static readonly Process termProc = GetTermProc();
    //# Get the process of the terminal connected to the current console application.
    //# Only Windows Terminal and Conhost are supported.
    //# Value:
    //#  If the terminal is Windows Terminal, the process of the belonging Windows Terminal instance will be returned.
    //#  If the terminal is Conhost, the process of the console application that spawned the Conhost instance will be returned.
    //#  If the function fails, null will be returned.
    public static Process TermProc { get { return termProc; } }
  }
'@

Add-Type @'
  using System;
  using System.Runtime.InteropServices;
  using System.Threading;

  //# for the second parameter of the Fader.Fade() method
  public enum FadeMode { Out, In }

  //# provides the .Fade() method for fading out or fading in a window
  public static class Fader {
    private static class NativeMethods {
      [DllImport("user32.dll")]
      internal static extern int GetWindowLongW(IntPtr wnd, int idx);
      [DllImport("user32.dll")]
      internal static extern int SetLayeredWindowAttributes(IntPtr wnd, int color, int alpha, int flags);
      [DllImport("user32.dll")]
      internal static extern int SetWindowLongW(IntPtr wnd, int idx, int newLong);
    }

    //# use alpha blending to fade the window
    public static void Fade(IntPtr hWnd, FadeMode mode) {
      if (hWnd == IntPtr.Zero) { return; }

      const int GWL_EXSTYLE = -20,
                WS_EX_LAYERED = 0x80000,
                LWA_ALPHA = 2;

      if (NativeMethods.SetWindowLongW(hWnd, GWL_EXSTYLE, NativeMethods.GetWindowLongW(hWnd, GWL_EXSTYLE) | WS_EX_LAYERED) == 0) { return; }

      if (mode == FadeMode.Out) {
        for (int alpha = 255; alpha >= 0; alpha -= 3) {
          if (NativeMethods.SetLayeredWindowAttributes(hWnd, 0, alpha, LWA_ALPHA) == 0) { return; }
          Thread.Sleep(1);
        }
        return;
      }

      for (int alpha = 0; alpha <= 255; alpha += 3) {
        if (NativeMethods.SetLayeredWindowAttributes(hWnd, 0, alpha, LWA_ALPHA) == 0) { return; }
        Thread.Sleep(1);
      }
    }
  }
'@


$termProc = [WinTerm]::TermProc
if ($termProc) {
  "Term proc: $($termProc.ProcessName)"
  "Term PID:  $($termProc.Id)"
  "Term HWND: $($termProc.MainWindowHandle.ToString('X8'))"

  # fading test to prove that we found the right terminal process
  [Fader]::Fade($termProc.MainWindowHandle, [FadeMode]::Out)
  [Fader]::Fade($termProc.MainWindowHandle, [FadeMode]::In)
} else {
  "Error"
}
