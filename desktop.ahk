#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off

; ════════════════════════════════════════════════════════════════════════════
;  UNIFIED WINDOW MANAGER  — Virtual Desktop Edition
;
;  VIRTUAL DESKTOP SWITCHING
;    Alt+1…9          → switch to desktop 1–9
;    Alt+Shift+1…9    → move active window to desktop and follow
;    Alt+WheelUp/Down → scroll through desktops (debounced)
;    Alt+Arrow keys   → focus nearest window in that direction
;    Alt+Shift+Q      → close active window
;    Ctrl+Alt+T       → open Windows Terminal
;
;  FOCUS BORDER  (Windows 11 Build 22000+; silently ignored on Windows 10)
;    Coloured DWM border blooms in on focus (ease-out, ~110 ms).
;
;  SYSTEM TRAY
;    Shows current desktop number.  Hover tooltip: "Desktop N of M".
;
;  REQUIREMENTS
;    • AutoHotkey v2.0 (64-bit recommended)
;    • VirtualDesktopAccessor.dll  in the same folder as this script
;      https://github.com/Ciantic/VirtualDesktopAccessor
;    • Windows 10 or 11
; ════════════════════════════════════════════════════════════════════════════

; ── Admin elevation ───────────────────────────────────────────────────────────
if !A_IsAdmin {
    Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp
}

DllCall("SetProcessDpiAwarenessContext", "Ptr", -4)
DllCall("winmm\timeBeginPeriod", "UInt", 1)

; ════════════════════════════════════════════════════════════════════════════
;  VIRTUALDESKTOPSACCESSOR.DLL
; ════════════════════════════════════════════════════════════════════════════
hVDA := DllCall("LoadLibrary", "Str", A_ScriptDir "\VirtualDesktopAccessor.dll", "Ptr")

GoToDesktopNumberProc         := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GoToDesktopNumber",         "Ptr")
MoveWindowToDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "MoveWindowToDesktopNumber", "Ptr")
GetWindowDesktopNumberProc    := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetWindowDesktopNumber",    "Ptr")
GetCurrentDesktopNumberProc   := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetCurrentDesktopNumber",   "Ptr")
GetDesktopCountProc           := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetDesktopCount",           "Ptr")

DllCall("QueryPerformanceFrequency", "Int64*", &QPCFreq := 0)

; ════════════════════════════════════════════════════════════════════════════
;  GLOBALS
; ════════════════════════════════════════════════════════════════════════════
global CurrentDesktop := DllCall(GetCurrentDesktopNumberProc, "Int")
global g_tLastScroll  := 0
global SCROLL_COOL_MS := 90
global g_hTrayIcon    := 0

; ── Focus border tunables ─────────────────────────────────────────────────────
global BORDER_COLOR   := 0xE56950
global BORDER_STEPS   := 14
global BORDER_ANIM_MS := 8

; ── Focus border state ────────────────────────────────────────────────────────
global g_bdrGui     := 0
global g_bdrFocused := 0
global g_animTarget := 0
global g_animStep   := 0

; ════════════════════════════════════════════════════════════════════════════
;  STARTUP
; ════════════════════════════════════════════════════════════════════════════
A_TrayMenu.Delete()
A_TrayMenu.Add("Reload", (*) => Reload())
A_TrayMenu.Add("Exit",   (*) => ExitApp())
OnExit(CleanupAll)
UpdateTrayIcon(CurrentDesktop)

g_bdrGui := Gui()
g_bdrGui.Opt("+LastFound")
DllCall("RegisterShellHookWindow", "Ptr", g_bdrGui.Hwnd)
global g_bdrMsgNum := DllCall("RegisterWindowMessage", "Str", "SHELLHOOK", "UInt")
OnMessage(g_bdrMsgNum, OnBorderShellMsg)
SetTimer(() => BorderFocusUpdate(WinExist("A")), -300)

; ════════════════════════════════════════════════════════════════════════════
;  HOTKEYS
; ════════════════════════════════════════════════════════════════════════════
^!t:: Run "wt.exe"

!1:: SwitchDesktop(0)
!2:: SwitchDesktop(1)
!3:: SwitchDesktop(2)
!4:: SwitchDesktop(3)
!5:: SwitchDesktop(4)
!6:: SwitchDesktop(5)
!7:: SwitchDesktop(6)
!8:: SwitchDesktop(7)
!9:: SwitchDesktop(8)

!+1:: MoveAndSwitch(0)
!+2:: MoveAndSwitch(1)
!+3:: MoveAndSwitch(2)
!+4:: MoveAndSwitch(3)
!+5:: MoveAndSwitch(4)
!+6:: MoveAndSwitch(5)
!+7:: MoveAndSwitch(6)
!+8:: MoveAndSwitch(7)
!+9:: MoveAndSwitch(8)

!+q:: try WinClose("A")

!Left::  FocusInDirection("left")
!Right:: FocusInDirection("right")
!Up::    FocusInDirection("up")
!Down::  FocusInDirection("down")

!WheelDown:: ScrollDesktop(1)
!WheelUp::   ScrollDesktop(-1)

; ════════════════════════════════════════════════════════════════════════════
;  DESKTOP SWITCHING
; ════════════════════════════════════════════════════════════════════════════
SwitchDesktop(num) {
    global CurrentDesktop, GoToDesktopNumberProc
    if num = CurrentDesktop
        return
    DllCall(GoToDesktopNumberProc, "Int", num)
    CurrentDesktop := num
    FocusTopmostOnDesktop(num)
    UpdateTrayIcon(num)
}

MoveAndSwitch(num) {
    global CurrentDesktop, GoToDesktopNumberProc, MoveWindowToDesktopNumberProc
    if num = CurrentDesktop
        return
    hwnd := WinExist("A")
    if !hwnd
        return
    DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", num)
    DllCall(GoToDesktopNumberProc, "Int", num)
    CurrentDesktop := num
    UpdateTrayIcon(num)

    ; The window isn't immediately visible after the desktop switch —
    ; retry activation a few times before giving up.
    loop 10 {
        try {
            if DllCall("IsWindow", "Ptr", hwnd) && DllCall("IsWindowVisible", "Ptr", hwnd) {
                WinActivate("ahk_id " hwnd)
                return
            }
        }
        Sleep(30)
    }
    ; Fallback: focus whatever's on top of the new desktop
    FocusTopmostOnDesktop(num)
}

ScrollDesktop(direction) {
    global CurrentDesktop, g_tLastScroll, QPCFreq, SCROLL_COOL_MS, GetDesktopCountProc
    DllCall("QueryPerformanceCounter", "Int64*", &now := 0)
    if ((now - g_tLastScroll) / QPCFreq * 1000.0) < SCROLL_COOL_MS
        return
    total  := DllCall(GetDesktopCountProc, "Int")
    total  := (total < 1) ? 9 : total
    target := CurrentDesktop + direction
    if target < 0 || target >= total
        return
    g_tLastScroll := now
    SwitchDesktop(target)
}

; ════════════════════════════════════════════════════════════════════════════
;  FOCUS HELPERS
; ════════════════════════════════════════════════════════════════════════════
FocusTopmostOnDesktop(num) {
    global GetWindowDesktopNumberProc
    WS_VISIBLE := 0x10000000
    for hwnd in WinGetList() {
        try {
            if !(WinGetStyle("ahk_id " hwnd) & WS_VISIBLE)
                continue
            if WinGetMinMax("ahk_id " hwnd) = -1
                continue
            if WinGetTitle("ahk_id " hwnd) = ""
                continue
            if DllCall(GetWindowDesktopNumberProc, "Ptr", hwnd, "Int") = num {
                WinActivate("ahk_id " hwnd)
                return
            }
        }
    }
    WinActivate("ahk_class Progman")
}

FocusInDirection(dir) {
    global GetWindowDesktopNumberProc, CurrentDesktop
    WS_VISIBLE  := 0x10000000
    PERP_WEIGHT := 2.5

    hwndActive := WinExist("A")
    if !hwndActive
        return

    WinGetPos(&ax, &ay, &aw, &ah, "ahk_id " hwndActive)
    acx := ax + aw * 0.5,  acy := ay + ah * 0.5
    bestHwnd  := 0,  bestScore := 1.0e18

    for hwnd in WinGetList() {
        if hwnd = hwndActive
            continue
        try {
            if !(WinGetStyle("ahk_id " hwnd) & WS_VISIBLE)
                continue
            if WinGetMinMax("ahk_id " hwnd) = -1
                continue
            if WinGetTitle("ahk_id " hwnd) = ""
                continue
            if DllCall(GetWindowDesktopNumberProc, "Ptr", hwnd, "Int") != CurrentDesktop
                continue
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
            dx := wx + ww * 0.5 - acx,  dy := wy + wh * 0.5 - acy
            if ((dir = "right" && dx <= 0) || (dir = "left"  && dx >= 0)
             || (dir = "down"  && dy <= 0) || (dir = "up"    && dy >= 0))
                continue
            primary := (dir = "right" || dir = "left") ? Abs(dx) : Abs(dy)
            perp    := (dir = "right" || dir = "left") ? Abs(dy) : Abs(dx)
            score   := primary + PERP_WEIGHT * perp
            if score < bestScore {
                bestScore := score,  bestHwnd := hwnd
            }
        }
    }
    if bestHwnd
        WinActivate("ahk_id " bestHwnd)
}

; ════════════════════════════════════════════════════════════════════════════
;  TRAY ICON
; ════════════════════════════════════════════════════════════════════════════
UpdateTrayIcon(desktopNum) {
    global g_hTrayIcon, GetDesktopCountProc

    SZ := 16
    hDC    := DllCall("GetDC", "Ptr", 0, "Ptr")
    hMemDC := DllCall("CreateCompatibleDC", "Ptr", hDC, "Ptr")

    bi := Buffer(40, 0)
    NumPut("UInt",  40, bi,  0), NumPut("Int",   SZ, bi, 4)
    NumPut("Int",  -SZ, bi,  8), NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)

    pBits := 0
    hBmp  := DllCall("CreateDIBSection", "Ptr", hMemDC, "Ptr", bi,
                     "UInt", 0, "Ptr*", &pBits, "Ptr", 0, "UInt", 0, "Ptr")
    hOld  := DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hBmp, "Ptr")
    DllCall("PatBlt", "Ptr", hMemDC, "Int", 0, "Int", 0, "Int", SZ, "Int", SZ, "UInt", 0x42)

    label    := String(desktopNum + 1)
    fontSize := (StrLen(label) = 1) ? 26 : 20

    hFont := DllCall("CreateFont",
        "Int", fontSize, "Int", 0, "Int", 0, "Int", 0, "Int", 700,
        "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
        "UInt", 5, "UInt", 0, "UInt", 0, "Str", "Segoe UI Variable Display", "Ptr")
    if !hFont
        hFont := DllCall("CreateFont",
            "Int", fontSize, "Int", 0, "Int", 0, "Int", 0, "Int", 700,
            "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 0,
            "UInt", 5, "UInt", 0, "UInt", 0, "Str", "Segoe UI", "Ptr")

    hOldFt := DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hFont, "Ptr")
    DllCall("SetBkMode", "Ptr", hMemDC, "Int", 1)

    rc  := Buffer(16, 0)
    rcS := Buffer(16, 0)
    NumPut("Int",    0, rc,  0), NumPut("Int",    0, rc,  4)
    NumPut("Int",   SZ, rc,  8), NumPut("Int",   SZ, rc, 12)
    NumPut("Int",    1, rcS, 0), NumPut("Int",    1, rcS, 4)
    NumPut("Int", SZ+1, rcS, 8), NumPut("Int", SZ+1, rcS, 12)

    DllCall("SetTextColor", "Ptr", hMemDC, "UInt", 0x001A1A1A)
    DllCall("DrawText", "Ptr", hMemDC, "Str", label, "Int", -1, "Ptr", rcS, "UInt", 0x25)
    DllCall("SetTextColor", "Ptr", hMemDC, "UInt", 0x00FFFFFF)
    DllCall("DrawText", "Ptr", hMemDC, "Str", label, "Int", -1, "Ptr", rc,  "UInt", 0x25)

    DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hOldFt)
    DllCall("DeleteObject", "Ptr", hFont)

    loop SZ * SZ {
        off := (A_Index - 1) * 4
        b := NumGet(pBits + off, "UChar"), g := NumGet(pBits + off + 1, "UChar")
        r := NumGet(pBits + off + 2, "UChar")
        if (r || g || b)
            NumPut("UChar", 255, pBits + off + 3)
    }

    hMask := DllCall("CreateBitmap", "Int", SZ, "Int", SZ, "UInt", 1, "UInt", 1, "Ptr", 0, "Ptr")
    ii    := Buffer(16 + A_PtrSize * 2, 0)
    NumPut("Int", 1, ii, 0), NumPut("Int", 0, ii, 4), NumPut("Int", 0, ii, 8)
    NumPut("Ptr", hMask, ii, 16), NumPut("Ptr", hBmp, ii, 16 + A_PtrSize)
    hIcon := DllCall("CreateIconIndirect", "Ptr", ii, "Ptr")

    DllCall("SelectObject", "Ptr", hMemDC, "Ptr", hOld)
    DllCall("DeleteObject", "Ptr", hBmp)
    DllCall("DeleteObject", "Ptr", hMask)
    DllCall("DeleteDC",     "Ptr", hMemDC)
    DllCall("ReleaseDC",    "Ptr", 0, "Ptr", hDC)

    TraySetIcon("HICON:" hIcon,, true)
    if g_hTrayIcon
        DllCall("DestroyIcon", "Ptr", g_hTrayIcon)
    g_hTrayIcon := hIcon

    total     := DllCall(GetDesktopCountProc, "Int")
    A_IconTip := "Desktop " (desktopNum + 1) " of " (total > 0 ? total : "?")
}

; ════════════════════════════════════════════════════════════════════════════
;  CLEANUP
; ════════════════════════════════════════════════════════════════════════════
CleanupAll(*) {
    BorderClearAll()
    global g_hTrayIcon
    if g_hTrayIcon {
        DllCall("DestroyIcon", "Ptr", g_hTrayIcon)
        g_hTrayIcon := 0
    }
}

; ════════════════════════════════════════════════════════════════════════════
;  FOCUS BORDER  (DWM accent, Win11 Build 22000+; silent no-op on Win10)
; ════════════════════════════════════════════════════════════════════════════
OnBorderShellMsg(wParam, lParam, msg, hwnd) {
    if (wParam = 4 || wParam = 32772)
        BorderFocusUpdate(lParam)
}

BorderFocusUpdate(newHwnd) {
    global g_bdrFocused, g_animTarget, g_animStep, BORDER_ANIM_MS
    if !newHwnd || !DllCall("IsWindow", "Ptr", newHwnd)
        return
    try {
        cls := WinGetClass("ahk_id " newHwnd)
        if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd"
         || cls = "Shell_SecondaryTrayWnd" || cls = "DV2ControlHost"
         || cls = "Windows.UI.Core.CoreWindow")
            return
        if !DllCall("IsWindowVisible", "Ptr", newHwnd)
            return
    } catch {
        return
    }

    if newHwnd = g_bdrFocused
        return

    if g_bdrFocused && DllCall("IsWindow", "Ptr", g_bdrFocused)
        _BorderSetRaw(g_bdrFocused, 0xFFFFFFFF)
    if g_animTarget && g_animTarget != newHwnd
        if DllCall("IsWindow", "Ptr", g_animTarget)
            _BorderSetRaw(g_animTarget, 0xFFFFFFFF)

    g_bdrFocused := newHwnd,  g_animTarget := newHwnd,  g_animStep := 0
    SetTimer(BorderAnimTick, BORDER_ANIM_MS)
}

BorderAnimTick() {
    global g_animTarget, g_animStep, g_bdrFocused
    global BORDER_STEPS, BORDER_ANIM_MS, BORDER_COLOR

    if !g_animTarget || !DllCall("IsWindow", "Ptr", g_animTarget) {
        SetTimer(BorderAnimTick, 0),  g_animTarget := 0
        return
    }

    g_animStep++
    if g_animStep >= BORDER_STEPS {
        _BorderSetColor(g_animTarget, BORDER_COLOR, 1.0)
        SetTimer(BorderAnimTick, 0),  g_animTarget := 0
        return
    }

    t    := g_animStep / BORDER_STEPS
    ease := 1.0 - (1.0 - t) ** 2
    _BorderSetColor(g_animTarget, BORDER_COLOR, 0.18 + (1.0 - 0.18) * ease)
}

_BorderSetColor(hwnd, rgbColor, factor) {
    r := Round(((rgbColor >> 16) & 0xFF) * factor)
    g := Round(((rgbColor >>  8) & 0xFF) * factor)
    b := Round(( rgbColor        & 0xFF) * factor)
    _BorderSetRaw(hwnd, (b << 16) | (g << 8) | r)
}

_BorderSetRaw(hwnd, colorRef) {
    static DWMWA_BORDER_COLOR := 34
    try DllCall("dwmapi\DwmSetWindowAttribute",
        "Ptr", hwnd, "Int", DWMWA_BORDER_COLOR, "Int*", colorRef, "Int", 4)
}

BorderClearAll() {
    global g_bdrFocused, g_animTarget
    SetTimer(BorderAnimTick, 0)
    if g_bdrFocused && DllCall("IsWindow", "Ptr", g_bdrFocused)
        _BorderSetRaw(g_bdrFocused, 0xFFFFFFFF)
    if g_animTarget && g_animTarget != g_bdrFocused
        if DllCall("IsWindow", "Ptr", g_animTarget)
            _BorderSetRaw(g_animTarget, 0xFFFFFFFF)
    g_bdrFocused := 0,  g_animTarget := 0
}
