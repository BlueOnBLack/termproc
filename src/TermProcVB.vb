﻿' Copyright (c) 2022 Steffen Illhardt
' 
' Permission is hereby granted, free of charge, to any person obtaining a copy of
' this software and associated documentation files (the "Software"), to deal in
' the Software without restriction, including without limitation the rights to
' use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
' the Software, and to permit persons to whom the Software is furnished to do so,
' subject to the following conditions:
' 
' The above copyright notice and this permission notice shall be included in all
' copies or substantial portions of the Software.
' 
' THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
' IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
' FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
' COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
' IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
' CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

' Min. req.: .NET Framework 4.5

Option Explicit On
Option Strict On

Imports System.Globalization
Imports System.Runtime.ConstrainedExecution
Imports System.Runtime.InteropServices
Imports System.Threading

Namespace TerminalProcess
  ' provides the TermProc property referencing the process of the terminal connected to the current console application
  Public Module WinTerm
    ' imports the used Windows API functions
    Private NotInheritable Class NativeMethods
      <DllImport("kernel32.dll")>
      Friend Shared Function CloseHandle(ByVal Hndl As IntPtr) As Integer
      End Function
      <DllImport("kernelbase.dll")>
      Friend Shared Function CompareObjectHandles(ByVal hFirst As IntPtr, ByVal hSecond As IntPtr) As Integer
      End Function
      <DllImport("kernel32.dll")>
      Friend Shared Function DuplicateHandle(ByVal SrcProcHndl As IntPtr, ByVal SrcHndl As IntPtr, ByVal TrgtProcHndl As IntPtr, <Out> ByRef TrgtHndl As IntPtr, ByVal Acc As Integer, ByVal Inherit As Integer, ByVal Opts As Integer) As Integer
      End Function
      <DllImport("kernel32.dll")>
      Friend Shared Function GetConsoleWindow() As IntPtr
      End Function
      <DllImport("kernel32.dll")>
      Friend Shared Function GetCurrentProcess() As IntPtr
      End Function
      <DllImport("user32.dll")>
      Friend Shared Function GetWindowThreadProcessId(ByVal hWnd As IntPtr, <Out> ByRef procId As UInteger) As UInteger
      End Function
      <DllImport("ntdll.dll")>
      Friend Shared Function NtQuerySystemInformation(ByVal SysInfClass As Integer, ByVal SysInf As IntPtr, ByVal SysInfLen As Integer, <Out> ByRef RetLen As Integer) As Integer
      End Function
      <DllImport("kernel32.dll")>
      Friend Shared Function OpenProcess(ByVal Acc As Integer, ByVal Inherit As Integer, ByVal ProcId As UInteger) As IntPtr
      End Function
      <DllImport("user32.dll")>
      Friend Shared Function SendMessageW(ByVal hWnd As IntPtr, ByVal Msg As Integer, ByVal wParam As IntPtr, ByVal lParam As IntPtr) As IntPtr
      End Function
    End Class

    ' owns an unmanaged resource
    ' the ctor qualifies a SafeRes object to manage either a pointer received from Marshal.AllocHGlobal(), or a handle
    Private Class SafeRes
      Inherits CriticalFinalizerObject
      Implements IDisposable

      ' resource type of a SafeRes object
      Friend Enum ResType
        MemoryPointer
        Handle
      End Enum

      Private _raw As System.IntPtr = IntPtr.Zero
      Private ReadOnly resourceType As ResType = ResType.MemoryPointer

      Friend Property Raw As IntPtr
        Get
          Return _raw
        End Get
        Private Set(ByVal value As IntPtr)
          _raw = value
        End Set
      End Property

      Friend ReadOnly Property IsInvalid As Boolean
        Get
          Return Raw = IntPtr.Zero OrElse Raw = New IntPtr(-1)
        End Get
      End Property

      ' constructs a SafeRes object from an unmanaged resource specified by parameter raw
      ' the resource must be either a pointer received from Marshal.AllocHGlobal() (specify resourceType ResType.MemoryPointer),
      ' or a handle (specify resourceType ResType.Handle)
      Friend Sub New(ByVal raw As IntPtr, ByVal resourceType As ResType)
        Me.Raw = raw
        Me.resourceType = resourceType
      End Sub

      Protected Overrides Sub Finalize()
        Dispose(False)
      End Sub

      Public Sub Dispose() Implements IDisposable.Dispose
        Dispose(True)
        GC.SuppressFinalize(Me)
      End Sub

      Protected Overridable Sub Dispose(ByVal disposing As Boolean)
        If IsInvalid Then Exit Sub

        If resourceType = ResType.MemoryPointer Then
          Marshal.FreeHGlobal(Raw)
          Raw = IntPtr.Zero
          Exit Sub
        End If

        If NativeMethods.CloseHandle(Raw) <> 0 Then Raw = New IntPtr(-1)
      End Sub
    End Class

    ' undocumented SYSTEM_HANDLE structure, SYSTEM_HANDLE_TABLE_ENTRY_INFO might be the actual name
    <StructLayout(LayoutKind.Sequential)>
    Private Structure SystemHandle
      Friend ReadOnly ProcId As UInteger ' PID of the process the SYSTEM_HANDLE belongs to
      Friend ReadOnly ObjTypeNum As Byte
      Friend ReadOnly Flgs As Byte
      Friend ReadOnly Handle As UShort ' value representing an opened handle in the process
      Friend ReadOnly pObj As IntPtr
      Friend ReadOnly Acc As UInteger
    End Structure

    ' Enumerate the opened handles in the WindowsTerminal.exe process specified by the process ID passed to termPid.
    ' Return termPid if one of the process handles points to the Shell process specified by the process ID passed to shellPid.
    ' Return 0 if the Shell process is not found.
    Private Function FindWTCallback(ByVal shellPid As UInteger, ByVal termPid As UInteger) As UInteger
      Const PROCESS_DUP_HANDLE = &H40, ' access right to duplicate handles
            PROCESS_QUERY_LIMITED_INFORMATION = &H1000, ' access right to retrieve certain process information
            STATUS_INFO_LENGTH_MISMATCH = -1073741820, ' NTSTATUS returned if we still didn't allocate enough memory
            SystemHandleInformation = 16 ' one of the SYSTEM_INFORMATION_CLASS values
      Dim status As Integer, ' retrieves the NTSTATUS return value
          infSize = &H10000 ' initially allocated memory size for the SYSTEM_HANDLE_INFORMATION object
      Dim len As Integer = Nothing, hDup As IntPtr = Nothing
      ' open a handle to the WindowsTerminal process, granting permissions to duplicate handles
      Using sHTerm As New SafeRes(NativeMethods.OpenProcess(PROCESS_DUP_HANDLE, 0, termPid), SafeRes.ResType.Handle)
        If sHTerm.IsInvalid Then Return 0
        ' open a handle to the Shell process
        Using sHShell As New SafeRes(NativeMethods.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, shellPid), SafeRes.ResType.Handle)
          If sHShell.IsInvalid Then Return 0

          ' allocate some memory representing an undocumented SYSTEM_HANDLE_INFORMATION object, which can't be meaningfully declared in C# code
          Dim pSysHndlInf = Marshal.AllocHGlobal(infSize)
          Do ' try to get an array of all available SYSTEM_HANDLE objects, allocate more memory if necessary
            status = NativeMethods.NtQuerySystemInformation(SystemHandleInformation, pSysHndlInf, infSize, len)
            If status <> STATUS_INFO_LENGTH_MISMATCH Then Exit Do
            Marshal.FreeHGlobal(pSysHndlInf)
            infSize = len
            pSysHndlInf = Marshal.AllocHGlobal(infSize)
          Loop

          Using sPSysHndlInf As New SafeRes(pSysHndlInf, SafeRes.ResType.MemoryPointer)
            If status < 0 Then Return 0

            Dim pid As UInteger = 0
            Dim hCur As IntPtr = NativeMethods.GetCurrentProcess()
            Dim sysHndlSize = Marshal.SizeOf(GetType(SystemHandle))
            ' iterate over the array of SYSTEM_HANDLE objects, which begins at an offset of pointer size in the SYSTEM_HANDLE_INFORMATION object
            ' the number of SYSTEM_HANDLE objects is specified in the first 32 bits of the SYSTEM_HANDLE_INFORMATION object
            Dim pSysHndl = sPSysHndlInf.Raw + IntPtr.Size, pEnd = pSysHndl + (Marshal.ReadInt32(sPSysHndlInf.Raw) * sysHndlSize)
            While pSysHndl <> pEnd
              ' get one SYSTEM_HANDLE at a time
              Dim sysHndl As SystemHandle = DirectCast(Marshal.PtrToStructure(pSysHndl, GetType(SystemHandle)), SystemHandle)
              ' if the SYSTEM_HANDLE object doesn't belong to the WindowsTerminal process, or
              ' if duplicating its Handle member fails, continue with the next SYSTEM_HANDLE object
              ' the duplicated handle is necessary to get information about the object (e.g. the process) it points to
              If sysHndl.ProcId <> termPid OrElse NativeMethods.DuplicateHandle(sHTerm.Raw, CType(sysHndl.Handle, IntPtr), hCur, hDup, PROCESS_QUERY_LIMITED_INFORMATION, 0, 0) = 0 Then
                pSysHndl += sysHndlSize
                Continue While
              End If

              ' at this point duplicating succeeded and thus, sHDup is valid
              Using sHDup As New SafeRes(hDup, SafeRes.ResType.Handle)
                ' compare the duplicated handle with the handle of our shell process
                ' if they point to the same kernel object, we are going to step out of the loop and return the PID of the WindowsTerminal process
                If NativeMethods.CompareObjectHandles(sHDup.Raw, sHShell.Raw) <> 0 Then
                  pid = termPid
                  Exit While
                End If
              End Using

              pSysHndl += sysHndlSize
            End While

            Return pid
          End Using
        End Using
      End Using
    End Function

    Private ReadOnly Property ConWnd As IntPtr = NativeMethods.GetConsoleWindow()

    Private Function GetTermProc() As Process
      Const WM_GETICON = &H7F

      ' Get the ID of the Shell process that spawned the Conhost process.
      Dim shellPid As UInteger = Nothing

      If NativeMethods.GetWindowThreadProcessId(ConWnd, shellPid) = 0 Then Return Nothing

      ' We don't have a proper way to figure out to what terminal app the Shell process
      ' is connected on the local machine:
      ' https://github.com/microsoft/terminal/issues/7434
      ' We're getting around this assuming we don't get an icon handle from the
      ' invisible Conhost window when the Shell is connected to Windows Terminal.
      If NativeMethods.SendMessageW(ConWnd, WM_GETICON, IntPtr.Zero, IntPtr.Zero) <> IntPtr.Zero Then
        ' Conhost assumed: The Shell process' main window is the console window.
        ' (weird because the Shell has no own window, but it has always been like this)
        Return Process.GetProcessById(CInt(shellPid))
      End If

      ' We don't have a proper way to figure out which WindowsTerminal process
      ' is connected with the Shell process:
      ' https://github.com/microsoft/terminal/issues/5694
      ' The assumption that the terminal is the parent process of the Shell process
      ' is gone with DefTerm (the Default Windows Terminal).
      ' Thus, I don't care about using more undocumented stuff:
      ' Get the process IDs of all WindowsTerminal processes and try to figure out
      ' which of them has a handle to the Shell process open.
      For Each trmProc In Process.GetProcessesByName("WindowsTerminal")
        Dim termPid = FindWTCallback(shellPid, CUInt(trmProc.Id))
        If termPid <> 0 Then Return trmProc
      Next

      Return Nothing
    End Function

    ' Get the process of the terminal connected to the current console application.
    ' Only Windows Terminal and Conhost are supported.
    ' Value:
    '  If the terminal is Windows Terminal, the process of the belonging Windows Terminal instance will be returned.
    '  If the terminal is Conhost, the process of the console application that spawned the Conhost instance will be returned.
    '  If the function fails, null will be returned.
    Public ReadOnly Property TermProc As Process = GetTermProc()
  End Module

  Friend Class Program
    Public Shared Function Main() As Integer
      Try
        Console.WriteLine("Term proc: {0}" & vbLf & "Term PID:  {1}" & vbLf & "Term HWND: {2}",
                          TermProc.ProcessName,
                          TermProc.Id.ToString(CultureInfo.CurrentCulture),
                          TermProc.MainWindowHandle.ToString("X8"))

        Test.Fade(TermProc.MainWindowHandle, Test.FadeMode.Out)
        Test.Fade(TermProc.MainWindowHandle, Test.FadeMode.In)
        Return 0
      Catch
        Return 1
      End Try
    End Function
  End Class
End Namespace

Namespace Test
  ' for the second parameter of the Fader.Fade() method
  Public Enum FadeMode
    Out
    [In]
  End Enum

  ' provides the .Fade() method for fading out or fading in a window, used to prove that we found the right terminal process
  Public Module Fader
    Private NotInheritable Class NativeMethods
      <DllImport("user32.dll")>
      Friend Shared Function GetWindowLongW(ByVal wnd As IntPtr, ByVal idx As Integer) As Integer
      End Function
      <DllImport("user32.dll")>
      Friend Shared Function SetLayeredWindowAttributes(ByVal wnd As IntPtr, ByVal color As Integer, ByVal alpha As Integer, ByVal flags As Integer) As Integer
      End Function
      <DllImport("user32.dll")>
      Friend Shared Function SetWindowLongW(ByVal wnd As IntPtr, ByVal idx As Integer, ByVal newLong As Integer) As Integer
      End Function
    End Class

    ' use alpha blending to fade the window
    Public Sub Fade(ByVal hWnd As IntPtr, ByVal mode As FadeMode)
      If hWnd = IntPtr.Zero Then Exit Sub

      Const GWL_EXSTYLE = -20, WS_EX_LAYERED = &H80000, LWA_ALPHA = 2

      If NativeMethods.SetWindowLongW(hWnd, GWL_EXSTYLE, NativeMethods.GetWindowLongW(hWnd, GWL_EXSTYLE) Or WS_EX_LAYERED) = 0 Then Exit Sub

      If mode = FadeMode.Out Then
        For alpha = 255 To 0 Step -3
          If NativeMethods.SetLayeredWindowAttributes(hWnd, 0, alpha, LWA_ALPHA) = 0 Then Exit Sub
          Thread.Sleep(1)
        Next
        Exit Sub
      End If

      For alpha = 0 To 255 Step 3
        If NativeMethods.SetLayeredWindowAttributes(hWnd, 0, alpha, LWA_ALPHA) = 0 Then Exit Sub
        Thread.Sleep(1)
      Next
    End Sub
  End Module
End Namespace