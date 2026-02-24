#Requires AutoHotkey v2.0

; Auto-elevate to admin if not already
if !A_IsAdmin {
    Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp
}

hVirtualDesktopAccessor := DllCall("LoadLibrary", "Str", A_ScriptDir "\VirtualDesktopAccessor.dll", "Ptr")
GoToDesktopNumberProc         := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GoToDesktopNumber", "Ptr")
MoveWindowToDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "MoveWindowToDesktopNumber", "Ptr")
GetWindowDesktopNumberProc    := DllCall("GetProcAddress", "Ptr", hVirtualDesktopAccessor, "AStr", "GetWindowDesktopNumber", "Ptr")

; Track windows we've already centered so minimize/restore doesn't re-center them
centeredWindows := Map()

; Hook into window show events to auto-center new windows
WinEventProc := CallbackCreate(CenterNewWindow, "F", 7)
hHook := DllCall("SetWinEventHook"
    , "UInt", 0x8002   ; EVENT_OBJECT_SHOW
    , "UInt", 0x8002
    , "Ptr",  0
    , "Ptr",  WinEventProc
    , "UInt", 0
    , "UInt", 0
    , "UInt", 0
    , "Ptr")

; Clean up hook on exit
OnExit((*) => DllCall("UnhookWinEvent", "Ptr", hHook))

; Switch to desktop
!1:: SwitchDesktop(0)
!2:: SwitchDesktop(1)
!3:: SwitchDesktop(2)
!4:: SwitchDesktop(3)
!5:: SwitchDesktop(4)
!6:: SwitchDesktop(5)
!7:: SwitchDesktop(6)
!8:: SwitchDesktop(7)
!9:: SwitchDesktop(8)

; Move active window to desktop (Alt+Shift+Number)
!+1:: MoveAndSwitch(0)
!+2:: MoveAndSwitch(1)
!+3:: MoveAndSwitch(2)
!+4:: MoveAndSwitch(3)
!+5:: MoveAndSwitch(4)
!+6:: MoveAndSwitch(5)
!+7:: MoveAndSwitch(6)
!+8:: MoveAndSwitch(7)
!+9:: MoveAndSwitch(8)

; Close active window
!+q:: {
    try WinClose("A")
}

SwitchDesktop(num) {
    DllCall(GoToDesktopNumberProc, "Int", num)
    Sleep(10)
    FocusTopmostOnDesktop(num)
}

MoveAndSwitch(num) {
    hwnd := WinExist("A")
    if !hwnd
        return
    DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", num)
    Sleep(50)
    DllCall(GoToDesktopNumberProc, "Int", num)
    Sleep(150)
    WinActivate("ahk_id " hwnd)
}

FocusTopmostOnDesktop(num) {
    windows := WinGetList()
    for hwnd in windows {
        try {
            if !WinGetStyle("ahk_id " hwnd) & 0x10000000
                continue
            if WinGetMinMax("ahk_id " hwnd) = -1
                continue
            if WinGetTitle("ahk_id " hwnd) = ""
                continue
            desktopNum := DllCall(GetWindowDesktopNumberProc, "Ptr", hwnd, "Int")
            if desktopNum = num {
                WinActivate("ahk_id " hwnd)
                return
            }
        }
    }
    ; No windows on this desktop — focus the desktop itself
    WinActivate("ahk_class Progman")
}

CenterNewWindow(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
    if idObject != 0 || idChild != 0
        return
    if centeredWindows.Has(hwnd)
        return
    centeredWindows[hwnd] := true

    Sleep(50)

    try {
        if !(WinGetStyle("ahk_id " hwnd) & 0x10000000)
            return
        if WinGetMinMax("ahk_id " hwnd) != 0
            return
        if WinGetTitle("ahk_id " hwnd) = ""
            return

        MonitorGetWorkArea(1, &left, &top, &right, &bottom)
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)

        if w < 10 || h < 10
            return

        newX := left + (right - left - w) // 2
        newY := top + (bottom - top - h) // 2
        WinMove(newX, newY,,, "ahk_id " hwnd)
    }
}
