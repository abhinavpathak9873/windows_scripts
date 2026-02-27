#Requires AutoHotkey v2.0
; NOTE: deliberately no #MaxThreadsPerHotkey — default 1 is correct here.
; All animation state is driven by a 5ms timer, not by blocking hotkey threads.

if !A_IsAdmin {
    Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp
}

; ── VDA ──────────────────────────────────────────────────────────────────────
hVDA := DllCall("LoadLibrary", "Str", A_ScriptDir "\VirtualDesktopAccessor.dll", "Ptr")
GoToDesktopNumberProc         := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GoToDesktopNumber",         "Ptr")
MoveWindowToDesktopNumberProc := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "MoveWindowToDesktopNumber", "Ptr")
GetWindowDesktopNumberProc    := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetWindowDesktopNumber",    "Ptr")
GetCurrentDesktopNumberProc   := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetCurrentDesktopNumber",   "Ptr")

DllCall("LoadLibrary", "Str", "dwmapi")          ; DwmFlush (used once, not in loops)
DllCall("winmm\timeBeginPeriod", "UInt", 1)      ; 1ms system timer resolution
DllCall("QueryPerformanceFrequency", "Int64*", &QPCFreq := 0)

; ── Work area ────────────────────────────────────────────────────────────────
MonitorGetWorkArea(, &wL, &wT, &wR, &wB)
global WorkW := wR - wL
global WorkH := wB - wT
global WorkX := wL
global WorkY := wT

global CurrentDesktop := DllCall(GetCurrentDesktopNumberProc, "Int")

; ── Tunables ─────────────────────────────────────────────────────────────────
ANIM_MS  := 150   ; crossfade duration in ms    — try 150–250
PRIME_MS := 35    ; wait for new desktop to paint before revealing (ms)

; ── Overlay ───────────────────────────────────────────────────────────────────
; +E0x80000 = WS_EX_LAYERED  +E0x20 = WS_EX_TRANSPARENT (click-through)
global OverlayGui  := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
OverlayGui.BackColor := "000000"
OverlayGui.Show("x" WorkX " y" WorkY " w" WorkW " h" WorkH " Hide NoActivate")
global OverlayHwnd := OverlayGui.Hwnd

; Pre-allocated ULW structs — filled once, reused every frame (zero alloc in hot path)
global g_ptDst := Buffer(8, 0)
NumPut("Int", WorkX, g_ptDst, 0), NumPut("Int", WorkY, g_ptDst, 4)
global g_ptSrc := Buffer(8, 0)   ; always 0,0 — source origin
global g_sz    := Buffer(8, 0)
NumPut("Int", WorkW, g_sz, 0), NumPut("Int", WorkH, g_sz, 4)
global g_Blend := Buffer(4, 0)
NumPut("UChar", 0, g_Blend, 0)   ; BlendOp  = AC_SRC_OVER
NumPut("UChar", 0, g_Blend, 1)   ; BlendFlags
NumPut("UChar", 0, g_Blend, 3)   ; AlphaFormat = 0 (use constant alpha only)

; ── Animation state ───────────────────────────────────────────────────────────
;   "idle"   → timer returns immediately
;   "primed" → overlay is at 255, waiting PRIME_MS for new desktop to paint
;   "fading" → reducing overlay alpha from 255→0 each tick
global g_State     := "idle"
global g_tMark     := 0       ; QPC timestamp (set when entering primed/fading)
global g_hCap      := 0       ; HBITMAP of the old desktop — painted on overlay
global g_hMemDC    := 0       ; compatible DC with g_hCap selected in
global g_hScreenDC := 0       ; GetDC(0) kept alive for ULW during animation
global g_Gen       := 0       ; generation counter — bumped on every cleanup to
                               ; invalidate stale AnimTick threads

; ── Timer: drives all animation, never blocks ─────────────────────────────────
;   5ms interval → up to 200fps. At 60Hz you get ~12 frames per 60ms fade.
;   At 144Hz you get ~28 frames. Timer returns between each frame, so hotkeys
;   can always interrupt within one tick (~5ms) at most.
SetTimer(AnimTick, 5)

; ── Hotkeys ───────────────────────────────────────────────────────────────────
^!t:: Run "wt.exe"

!1::  SwitchDesktop(0)
!2::  SwitchDesktop(1)
!3::  SwitchDesktop(2)
!4::  SwitchDesktop(3)
!5::  SwitchDesktop(4)
!6::  SwitchDesktop(5)
!7::  SwitchDesktop(6)
!8::  SwitchDesktop(7)
!9::  SwitchDesktop(8)

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

; ════════════════════════════════════════════════════════════════════════════
;  ANIMATION TIMER
;  Called every 5ms by AHK's scheduler.  Returns fast — never blocks.
;  No DwmFlush, no Sleep, no loops.  One ULW call per tick max.
; ════════════════════════════════════════════════════════════════════════════
AnimTick() {
    global g_State, g_tMark, QPCFreq, PRIME_MS, ANIM_MS
    global g_Blend, g_ptDst, g_ptSrc, g_sz
    global g_hMemDC, g_hScreenDC, OverlayHwnd, OverlayGui, g_Gen

    ; Fast-exit when idle (runs every 5ms — keep this branch nearly free)
    if g_State = "idle"
        return

    ; Snapshot generation at entry — if a hotkey fires mid-tick and starts a
    ; new transition, g_Gen will no longer match and we bail rather than
    ; double-freeing the new animation's handles.
    myGen := g_Gen

    DllCall("QueryPerformanceCounter", "Int64*", &now := 0)
    elapsed := (now - g_tMark) / QPCFreq * 1000.0   ; elapsed ms since mark

    ; ── Primed: wait for new desktop to fully paint ──────────────────────────
    if g_State = "primed" {
        if elapsed < PRIME_MS
            return
        ; Enough time has passed — start the actual fade
        DllCall("QueryPerformanceCounter", "Int64*", &g_tMark := 0)
        g_State := "fading"
        elapsed := 0.0
    }

    ; ── Guard: bail if a hotkey replaced our handles while we were computing ──
    if g_Gen != myGen || !g_hMemDC || !g_hScreenDC
        return

    t     := Min(elapsed / ANIM_MS, 1.0)
    e     := t * t * (3.0 - 2.0 * t)        ; smoothstep S-curve (gentle at both ends)
    alpha := Round(255 * (1.0 - e))

    NumPut("UChar", alpha, g_Blend, 2)
    DllCall("UpdateLayeredWindow",
        "Ptr",  OverlayHwnd,
        "Ptr",  g_hScreenDC,   ; screen DC (kept open for animation lifetime)
        "Ptr",  g_ptDst,       ; destination position (constant)
        "Ptr",  g_sz,          ; size (constant)
        "Ptr",  g_hMemDC,      ; source: memory DC with old-desktop bitmap
        "Ptr",  g_ptSrc,       ; source origin 0,0
        "UInt", 0,             ; no color key
        "Ptr",  g_Blend,
        "UInt", 2)             ; ULW_ALPHA

    ; Re-check generation before touching shared state at t==1 —
    ; a hotkey may have fired during UpdateLayeredWindow and started a fresh
    ; transition; in that case we must not clean up its brand-new handles.
    if t >= 1.0 && g_Gen = myGen {
        OverlayGui.Hide()
        CleanupAnim()
    }
}

; ════════════════════════════════════════════════════════════════════════════
;  GDI HELPERS
; ════════════════════════════════════════════════════════════════════════════

; Full work-area screenshot → HBITMAP.  Self-contained: opens/closes its own DCs.
CaptureScreen() {
    global WorkX, WorkY, WorkW, WorkH
    hDC  := DllCall("GetDC",                  "Ptr", 0,   "Ptr")
    hMem := DllCall("CreateCompatibleDC",     "Ptr", hDC, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hDC, "Int", WorkW, "Int", WorkH, "Ptr")
    DllCall("SelectObject", "Ptr", hMem, "Ptr", hBmp)
    DllCall("BitBlt",
        "Ptr", hMem, "Int", 0,     "Int", 0, "Int", WorkW, "Int", WorkH,
        "Ptr", hDC,  "Int", WorkX, "Int", WorkY, "UInt", 0x00CC0020)   ; SRCCOPY
    DllCall("DeleteDC",  "Ptr", hMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)
    return hBmp
}

; Free all animation resources and return to idle.
; Safe to call even when already idle.
; Increments g_Gen so any in-flight AnimTick that snaphotted the old generation
; will see the mismatch and exit without touching the (now-freed) handles.
CleanupAnim() {
    global g_State, g_hCap, g_hMemDC, g_hScreenDC, g_Gen
    if (g_hMemDC) {
        DllCall("DeleteDC", "Ptr", g_hMemDC)
        g_hMemDC := 0
    }
    if (g_hCap) {
        DllCall("DeleteObject", "Ptr", g_hCap)
        g_hCap := 0
    }
    if (g_hScreenDC) {
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", g_hScreenDC)
        g_hScreenDC := 0
    }
    g_Gen++
    g_State := "idle"
}
; ════════════════════════════════════════════════════════════════════════════
;  BEGIN TRANSITION
;  1. Instantly aborts any in-flight animation (no waiting)
;  2. Captures the current desktop (overlay is hidden → clean image)
;  3. Paints capture onto overlay and shows it at full opacity
;  4. Calls DwmFlush ONCE to guarantee overlay is on-screen before
;     the desktop switch fires.  This is the only blocking call in the
;     entire script, and it runs only in the hotkey handler, not in any loop.
;  Returns with g_State still "idle" — caller sets "primed" after switching.
; ════════════════════════════════════════════════════════════════════════════
BeginTransition() {
    global g_State, g_hCap, g_hMemDC, g_hScreenDC
    global OverlayGui, OverlayHwnd, g_ptDst, g_ptSrc, g_sz, g_Blend

    ; ── 1. Abort any current animation ────────────────────────────────────────
    if g_State != "idle" {
        OverlayGui.Hide()   ; hide BEFORE capturing so capture is clean
        CleanupAnim()
    }

    ; ── 2. Capture the current (clean, no-overlay) desktop ───────────────────
    g_hScreenDC := DllCall("GetDC", "Ptr", 0, "Ptr")   ; kept alive for animation
    g_hCap      := CaptureScreen()
    g_hMemDC    := DllCall("CreateCompatibleDC", "Ptr", g_hScreenDC, "Ptr")
    DllCall("SelectObject", "Ptr", g_hMemDC, "Ptr", g_hCap)

    ; ── 3. Paint overlay and show ─────────────────────────────────────────────
    NumPut("UChar", 255, g_Blend, 2)   ; full opacity — looks identical to desktop
    DllCall("UpdateLayeredWindow",
        "Ptr", OverlayHwnd, "Ptr", g_hScreenDC,
        "Ptr", g_ptDst,     "Ptr", g_sz,
        "Ptr", g_hMemDC,    "Ptr", g_ptSrc,
        "UInt", 0,          "Ptr", g_Blend, "UInt", 2)
    OverlayGui.Show("NoActivate")

    ; ── 4. Wait for DWM to composite the overlay before the switch ────────────
    ;   Without this, DWM renders the live desktop for 1 frame before the overlay
    ;   appears — causing a visible blink. One DwmFlush (≤16ms @ 60Hz, ≤7ms @
    ;   144Hz) is all we need. It's called once here, never inside a loop.
    DllCall("dwmapi\DwmFlush")
}

; ════════════════════════════════════════════════════════════════════════════
;  PUBLIC ACTIONS
; ════════════════════════════════════════════════════════════════════════════
;
;  How the crossfade works:
;    BeginTransition() captures the old desktop and shows it on the overlay.
;    The actual desktop switch (GoToDesktopNumber) then happens underneath
;    the fully-opaque overlay — completely invisible to the user.
;    After PRIME_MS, the timer starts fading the overlay from 255→0.
;    As it fades, the new live desktop shows through underneath.
;    Result: a smooth dissolve from old desktop to new desktop.
;    No per-frame bitmap compositing needed — DWM does the alpha blend for free.
;
;  For MoveAndSwitch:
;    The moved window stays at the same screen position on both desktops
;    (VirtualDesktopAccessor preserves geometry).  As the overlay fades, the
;    moved window fades in at exactly the same position → appears stationary.

SwitchDesktop(num) {
    global CurrentDesktop, g_State, g_tMark

    if num = CurrentDesktop
        return

    BeginTransition()   ; ~5ms + 1 DwmFlush (~7–16ms depending on Hz)

    DllCall(GoToDesktopNumberProc, "Int", num)
    CurrentDesktop := num
    FocusTopmostOnDesktop(num)

    DllCall("QueryPerformanceCounter", "Int64*", &g_tMark := 0)
    g_State := "primed"   ; timer takes over from here — hotkey handler returns
}

MoveAndSwitch(num) {
    global CurrentDesktop, g_State, g_tMark

    if num = CurrentDesktop
        return

    hwnd := WinExist("A")
    if !hwnd
        return

    BeginTransition()

    DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", num)
    DllCall(GoToDesktopNumberProc,         "Int", num)
    CurrentDesktop := num
    WinActivate("ahk_id " hwnd)   ; async — returns immediately

    DllCall("QueryPerformanceCounter", "Int64*", &g_tMark := 0)
    g_State := "primed"
}

; ════════════════════════════════════════════════════════════════════════════
;  FOCUS HELPER
; ════════════════════════════════════════════════════════════════════════════

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
            if DllCall(GetWindowDesktopNumberProc, "Ptr", hwnd, "Int") = num {
                WinActivate("ahk_id " hwnd)
                return
            }
        }
    }
    WinActivate("ahk_class Progman")
}
