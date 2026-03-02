#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off

if !A_IsAdmin {
    Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp
}

DllCall("SetProcessDpiAwarenessContext", "Ptr", -4)
DllCall("winmm\timeBeginPeriod", "UInt", 1)

global SWP_KINETIC := 0x0214
global SWP_SHOW    := 0x0254
global SWP_HIDE    := 0x0297
global DWMWA_EXTENDED_FRAME_BOUNDS := 9
global EVENT_SYSTEM_MOVESIZESTART  := 0x000A
global EVENT_SYSTEM_MOVESIZEEND    := 0x000B
global WINEVENT_OUTOFCONTEXT       := 0x0000

global GAP         := 0
global SNAP_EDGE   := 24
global SNAP_CORNER := 80
global MIN_W       := 240
global MIN_H       := 120
global DRAG_MS     := 2
global PREVIEW_MAX := 175
global PREVIEW_IN  := 22
global PREVIEW_OUT := 32

global g_vdm := 0

InitVDM() {
    global g_vdm
    try {
        g_vdm := ComObject("{AA509086-5CA9-4C25-8F95-589D3C07B48A}",
                           "{A5CD92FF-29BE-454C-8D04-D82879FB3F1B}")
    }
}
InitVDM()

GetWindowDesktopKey(hwnd) {
    global g_vdm
    if !g_vdm
        return "default"
    guid := Buffer(16, 0)
    try {
        hr := ComCall(4, g_vdm, "Ptr", hwnd, "Ptr", guid, "Int")
        if (hr != 0)
            return "default"
    } catch {
        return "default"
    }
    key := ""
    loop 16
        key .= Format("{:02X}", NumGet(guid, A_Index - 1, "UChar"))
    return key
}

IsWindowOnCurrentDesktop(hwnd) {
    global g_vdm
    if !g_vdm
        return true
    result := 0
    try {
        ComCall(3, g_vdm, "Ptr", hwnd, "Int*", &result, "Int")
    } catch {
        return true
    }
    return (result != 0)
}

global g_accentRGB := "0078D4"

ReadAccentColor() {
    global g_accentRGB
    try {
        raw := RegRead("HKCU\SOFTWARE\Microsoft\Windows\DWM", "AccentColor")
        b := Round(((raw >> 8)  & 0xFF) * 0.55)
        g := Round(((raw >> 16) & 0xFF) * 0.55)
        r := Round(((raw >> 24) & 0xFF) * 0.55)
        g_accentRGB := Format("{:02X}{:02X}{:02X}", r, g, b)
    }
}
ReadAccentColor()

global g_ptBuf := Buffer(8,  0)
global g_rcBuf := Buffer(16, 0)
global g_miBuf := Buffer(40, 0)
NumPut("UInt", 40, g_miBuf, 0)

global PreviewGui  := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
PreviewGui.BackColor := g_accentRGB
PreviewGui.Show("Hide")
global PreviewHwnd := PreviewGui.Hwnd
DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)

global g_snapped  := Map()
global g_preSnap  := Map()
global g_divV_map := Map()
global g_divH_map := Map()
global g_deskKey  := "default"

global g_hwnd  := 0
global g_mode  := ""
global g_mx0   := 0
global g_my0   := 0
global g_wx0   := 0
global g_wy0   := 0
global g_ww0   := 0
global g_wh0   := 0
global g_rdir  := ""
global g_zone  := ""
global g_unmax := false
global g_wa    := {x:0, y:0, w:0, h:0, r:0, b:0}

global g_prevAlpha   := 0
global g_prevVisible := false

global g_linked  := ""
global g_divBase := 0
global g_lSide   := []
global g_rSide   := []

global g_nativeDragHwnd    := 0
global g_nativeDragActive  := false
global g_nativeZone        := ""
global g_nativePrevAlpha   := 0
global g_nativePrevVisible := false
global g_nativeDragWasMax  := false
global g_nativeDragStartX  := 0
global g_nativeDragStartY  := 0
global NATIVE_SNAP_MIN_DIST := 40

global g_cbStart   := 0
global g_cbEnd     := 0
global g_hookStart := 0
global g_hookEnd   := 0

; ── Hotkeys ───────────────────────────────────────────────────────────────────
!LButton:: DragBegin("move")
!RButton:: DragBegin("resize")
#Left::    SnapKeyLeft()
#Right::   SnapKeyRight()
#Up::      SnapKeyUp()
#Down::    SnapKeyDown()

; ── Win32 helpers ─────────────────────────────────────────────────────────────
CurPos() {
    global g_ptBuf
    DllCall("GetCursorPos", "Ptr", g_ptBuf)
    return {x: NumGet(g_ptBuf, 0, "Int"), y: NumGet(g_ptBuf, 4, "Int")}
}

WinRect(hwnd) {
    global g_rcBuf
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", g_rcBuf)
    x := NumGet(g_rcBuf,  0, "Int")
    y := NumGet(g_rcBuf,  4, "Int")
    r := NumGet(g_rcBuf,  8, "Int")
    b := NumGet(g_rcBuf, 12, "Int")
    return {x:x, y:y, w:r-x, h:b-y, r:r, b:b}
}

WinVisibleBounds(hwnd) {
    global g_rcBuf, DWMWA_EXTENDED_FRAME_BOUNDS
    hr := DllCall("dwmapi\DwmGetWindowAttribute",
        "Ptr", hwnd,
        "UInt", DWMWA_EXTENDED_FRAME_BOUNDS,
        "Ptr", g_rcBuf,
        "UInt", 16,
        "UInt")
    if (hr != 0)
        DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", g_rcBuf)
    x := NumGet(g_rcBuf,  0, "Int")
    y := NumGet(g_rcBuf,  4, "Int")
    r := NumGet(g_rcBuf,  8, "Int")
    b := NumGet(g_rcBuf, 12, "Int")
    return {x:x, y:y, w:r-x, h:b-y, r:r, b:b}
}

GetShadowOverhang(hwnd) {
    rect    := WinRect(hwnd)
    visible := WinVisibleBounds(hwnd)
    return {
        left:   visible.x - rect.x,
        top:    visible.y - rect.y,
        right:  rect.r    - visible.r,
        bottom: rect.b    - visible.b,
        h:      (visible.x - rect.x) + (rect.r - visible.r),
        v:      (visible.y - rect.y) + (rect.b - visible.b)
    }
}

WorkAreaAt(px, py) {
    global g_ptBuf, g_miBuf
    NumPut("Int", px, g_ptBuf, 0)
    NumPut("Int", py, g_ptBuf, 4)
    packed := NumGet(g_ptBuf, 0, "Int64")
    hMon   := DllCall("MonitorFromPoint", "Int64", packed, "UInt", 2, "Ptr")
    DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", g_miBuf)
    x := NumGet(g_miBuf, 20, "Int")
    y := NumGet(g_miBuf, 24, "Int")
    r := NumGet(g_miBuf, 28, "Int")
    b := NumGet(g_miBuf, 32, "Int")
    return {x:x, y:y, r:r, b:b, w:r-x, h:b-y}
}

PosWinContent(hwnd, x, y, w, h) {
    global SWP_KINETIC
    o := GetShadowOverhang(hwnd)
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", x - o.left,
        "Int", y - o.top,
        "Int", w + o.h,
        "Int", h + o.v,
        "UInt", SWP_KINETIC)
}

ShowOverlay(hwnd, x, y, w, h) {
    global SWP_SHOW
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1,
        "Int", x, "Int", y, "Int", w, "Int", h, "UInt", SWP_SHOW)
}

HideOverlay(hwnd) {
    global SWP_HIDE
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0,
        "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", SWP_HIDE)
}

; ── Snap geometry ─────────────────────────────────────────────────────────────
DivV() {
    global g_divV_map, g_deskKey, g_wa
    if g_divV_map.Has(g_deskKey)
        return g_divV_map[g_deskKey]
    return g_wa.x + g_wa.w // 2
}

DivH() {
    global g_divH_map, g_deskKey, g_wa
    if g_divH_map.Has(g_deskKey)
        return g_divH_map[g_deskKey]
    return g_wa.y + g_wa.h // 2
}

GetContentWorkArea() {
    global g_wa, GAP
    return {
        x: g_wa.x + GAP,
        y: g_wa.y + GAP,
        r: g_wa.r - GAP,
        b: g_wa.b - GAP,
        w: g_wa.w - GAP * 2,
        h: g_wa.h - GAP * 2
    }
}

SnapRect(zone) {
    global GAP
    wa := GetContentWorkArea()
    vx := DivV()
    hy := DivH()
    hg := GAP // 2
    switch zone {
        case "max":
            return {x: wa.x,    y: wa.y,    w: wa.w,           h: wa.h}
        case "left":
            return {x: wa.x,    y: wa.y,    w: vx - wa.x - hg, h: wa.h}
        case "right":
            return {x: vx + hg, y: wa.y,    w: wa.r - vx - hg, h: wa.h}
        case "tl":
            return {x: wa.x,    y: wa.y,    w: vx - wa.x - hg, h: hy - wa.y - hg}
        case "tr":
            return {x: vx + hg, y: wa.y,    w: wa.r - vx - hg, h: hy - wa.y - hg}
        case "bl":
            return {x: wa.x,    y: hy + hg, w: vx - wa.x - hg, h: wa.b - hy - hg}
        case "br":
            return {x: vx + hg, y: hy + hg, w: wa.r - vx - hg, h: wa.b - hy - hg}
        default:
            return {x: wa.x, y: wa.y, w: wa.w, h: wa.h}
    }
}

CalcSnapZone(mx, my) {
    global SNAP_EDGE, SNAP_CORNER, g_wa
    rx := mx - g_wa.x
    ry := my - g_wa.y
    if (rx <= SNAP_CORNER && ry <= SNAP_CORNER)
        return "tl"
    if (rx >= g_wa.w - SNAP_CORNER && ry <= SNAP_CORNER)
        return "tr"
    if (rx <= SNAP_CORNER && ry >= g_wa.h - SNAP_CORNER)
        return "bl"
    if (rx >= g_wa.w - SNAP_CORNER && ry >= g_wa.h - SNAP_CORNER)
        return "br"
    if (ry <= SNAP_EDGE)
        return "max"
    if (rx <= SNAP_EDGE)
        return "left"
    if (rx >= g_wa.w - SNAP_EDGE)
        return "right"
    return ""
}

; ── Smart snap filling ────────────────────────────────────────────────────────
ZoneOccupied(zone) {
    global g_snapped
    for hwnd, z in g_snapped {
        if (z = zone && IsWindowOnCurrentDesktop(hwnd))
            return true
    }
    return false
}

ResolveSnapZone(requested) {
    switch requested {
        case "right":
            if (ZoneOccupied("tr") && !ZoneOccupied("br"))
                return "br"
            if (ZoneOccupied("br") && !ZoneOccupied("tr"))
                return "tr"
            return "right"
        case "left":
            if (ZoneOccupied("tl") && !ZoneOccupied("bl"))
                return "bl"
            if (ZoneOccupied("bl") && !ZoneOccupied("tl"))
                return "tl"
            return "left"
        default:
            return requested
    }
}

EvictContainedZones(zone) {
    global g_snapped
    toRemove := []
    if (zone = "left") {
        for hwnd, z in g_snapped {
            if IsWindowOnCurrentDesktop(hwnd) && (z = "tl" || z = "bl")
                toRemove.Push(hwnd)
        }
    } else if (zone = "right") {
        for hwnd, z in g_snapped {
            if IsWindowOnCurrentDesktop(hwnd) && (z = "tr" || z = "br")
                toRemove.Push(hwnd)
        }
    } else if (zone = "max") {
        for hwnd, z in g_snapped {
            if IsWindowOnCurrentDesktop(hwnd)
                toRemove.Push(hwnd)
        }
    }
    for hwnd in toRemove
        g_snapped.Delete(hwnd)
}

PruneSnapped() {
    global g_snapped
    toRemove := []
    for hwnd, zone in g_snapped {
        if !DllCall("IsWindow", "Ptr", hwnd)
            toRemove.Push(hwnd)
    }
    for hwnd in toRemove
        g_snapped.Delete(hwnd)
}

; ── Pre-snap position ─────────────────────────────────────────────────────────
RecordPreSnap(hwnd) {
    global g_preSnap, g_snapped
    if g_preSnap.Has(hwnd)
        return
    if g_snapped.Has(hwnd)
        return
    vis := WinVisibleBounds(hwnd)
    g_preSnap[hwnd] := {x: vis.x, y: vis.y, w: vis.w, h: vis.h}
}

RestoreFloating(hwnd) {
    global g_preSnap, g_snapped
    if g_snapped.Has(hwnd)
        g_snapped.Delete(hwnd)
    if (WinGetMinMax("ahk_id " hwnd) = 1)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
    if g_preSnap.Has(hwnd) {
        r := g_preSnap[hwnd]
        PosWinContent(hwnd, r.x, r.y, r.w, r.h)
        g_preSnap.Delete(hwnd)
    }
}

; ── Linked resize setup ───────────────────────────────────────────────────────
TrySetupLinkedResize(hwnd, rdir) {
    global g_snapped, g_linked, g_divBase, g_lSide, g_rSide

    if !g_snapped.Has(hwnd)
        return false

    zone    := g_snapped[hwnd]
    isLeft  := (zone = "left" || zone = "tl" || zone = "bl")
    isRight := (zone = "right" || zone = "tr" || zone = "br")
    isTop   := (zone = "tl" || zone = "tr")
    isBot   := (zone = "bl" || zone = "br")

    divType := ""
    if (isLeft  && InStr(rdir, "e"))
        divType := "V"
    if (isRight && InStr(rdir, "w"))
        divType := "V"
    if (isTop   && InStr(rdir, "s"))
        divType := "H"
    if (isBot   && InStr(rdir, "n"))
        divType := "H"

    if (divType = "")
        return false

    lSide := []
    rSide := []

    if (divType = "V") {
        for h, z in g_snapped {
            if !IsWindowOnCurrentDesktop(h)
                continue
            if (z = "left" || z = "tl" || z = "bl") {
                vis := WinVisibleBounds(h)
                lSide.Push({hwnd: h, zone: z, y: vis.y, h: vis.h})
            } else if (z = "right" || z = "tr" || z = "br") {
                vis := WinVisibleBounds(h)
                rSide.Push({hwnd: h, zone: z, y: vis.y, h: vis.h})
            }
        }
        if (lSide.Length < 1 || rSide.Length < 1)
            return false
        g_linked  := "V"
        g_divBase := DivV()
        g_lSide   := lSide
        g_rSide   := rSide
    } else {
        for h, z in g_snapped {
            if !IsWindowOnCurrentDesktop(h)
                continue
            if (z = "tl" || z = "tr") {
                vis := WinVisibleBounds(h)
                lSide.Push({hwnd: h, zone: z, x: vis.x, w: vis.w})
            } else if (z = "bl" || z = "br") {
                vis := WinVisibleBounds(h)
                rSide.Push({hwnd: h, zone: z, x: vis.x, w: vis.w})
            }
        }
        if (lSide.Length < 1 || rSide.Length < 1)
            return false
        g_linked  := "H"
        g_divBase := DivH()
        g_lSide   := lSide
        g_rSide   := rSide
    }

    return true
}

; ════════════════════════════════════════════════════════════════════════════
;  DRAG BEGIN
; ════════════════════════════════════════════════════════════════════════════
DragBegin(mode) {
    global g_hwnd, g_mode, g_mx0, g_my0, g_wx0, g_wy0, g_ww0, g_wh0
    global g_rdir, g_zone, g_unmax, g_wa, DRAG_MS
    global g_prevAlpha, g_prevVisible, PreviewHwnd
    global g_linked, g_lSide, g_rSide, g_snapped
    global g_divV_map, g_divH_map, g_deskKey, MIN_W, MIN_H, GAP

    PruneSnapped()
    MouseGetPos(,, &hwnd)
    if !hwnd
        return

    hwnd := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
    if !hwnd
        return

    cls := WinGetClass("ahk_id " hwnd)
    if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd"
     || cls = "Shell_SecondaryTrayWnd" || cls = "DV2ControlHost")
        return

    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return
    if DllCall("IsIconic", "Ptr", hwnd)
        return

    cp := CurPos()
    mx := cp.x
    my := cp.y
    vis := WinVisibleBounds(hwnd)
    g_deskKey := GetWindowDesktopKey(hwnd)

    g_unmax := false
    if (WinGetMinMax("ahk_id " hwnd) = 1) {
        if (mode = "move") {
            wa := WorkAreaAt(mx, my)
            rw := Round(wa.w * 0.60)
            rh := Round(wa.h * 0.65)
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
            PosWinContent(hwnd, mx - Round(rw * 0.30), wa.y + GAP, rw, rh)
            vis     := WinVisibleBounds(hwnd)
            g_unmax := true
        } else {
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
            vis := WinVisibleBounds(hwnd)
        }
    }

    g_wa := WorkAreaAt(mx, my)
    cwa  := GetContentWorkArea()

    if g_divV_map.Has(g_deskKey) {
        dv := g_divV_map[g_deskKey]
        if (dv < cwa.x + MIN_W || dv > cwa.r - MIN_W)
            g_divV_map.Delete(g_deskKey)
    }
    if g_divH_map.Has(g_deskKey) {
        dh := g_divH_map[g_deskKey]
        if (dh < cwa.y + MIN_H || dh > cwa.b - MIN_H)
            g_divH_map.Delete(g_deskKey)
    }

    if (mode = "move" && g_snapped.Has(hwnd))
        g_snapped.Delete(hwnd)

    g_hwnd := hwnd
    g_mode := mode
    g_mx0  := mx
    g_my0  := my
    g_wx0  := vis.x
    g_wy0  := vis.y
    g_ww0  := vis.w
    g_wh0  := vis.h
    g_zone := ""

    g_prevAlpha   := 0
    g_prevVisible := false
    g_linked      := ""
    DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)

    if (mode = "resize") {
        rc  := WinRect(hwnd)
        et  := Max(32, Min(80, Round(Min(rc.w, rc.h) * 0.20)))
        inN := (my - rc.y) < et
        inS := (rc.y + rc.h - my) < et
        inW := (mx - rc.x) < et
        inE := (rc.x + rc.w - mx) < et

        if (inN && inW)
            g_rdir := "nw"
        else if (inN && inE)
            g_rdir := "ne"
        else if (inS && inW)
            g_rdir := "sw"
        else if (inS && inE)
            g_rdir := "se"
        else if inN
            g_rdir := "n"
        else if inS
            g_rdir := "s"
        else if inW
            g_rdir := "w"
        else if inE
            g_rdir := "e"
        else if (mx < rc.x + rc.w // 2 && my < rc.y + rc.h // 2)
            g_rdir := "nw"
        else if (mx >= rc.x + rc.w // 2 && my < rc.y + rc.h // 2)
            g_rdir := "ne"
        else if (mx < rc.x + rc.w // 2)
            g_rdir := "sw"
        else
            g_rdir := "se"

        if !TrySetupLinkedResize(hwnd, g_rdir) {
            if g_snapped.Has(hwnd)
                g_snapped.Delete(hwnd)
        }
    }

    DllCall("SetForegroundWindow", "Ptr", hwnd)
    SetTimer(DragTick, DRAG_MS)

    if (mode = "move")
        KeyWait("LButton")
    else
        KeyWait("RButton")

    SetTimer(DragTick, 0)
    DragEnd()
}

; ════════════════════════════════════════════════════════════════════════════
;  DRAG TICK
; ════════════════════════════════════════════════════════════════════════════
DragTick() {
    global g_hwnd, g_mode, g_mx0, g_my0, g_wx0, g_wy0, g_ww0, g_wh0
    global g_rdir, g_zone, g_unmax, g_wa
    global g_prevAlpha, g_prevVisible, PreviewHwnd
    global g_linked, g_divBase, g_lSide, g_rSide
    global MIN_W, MIN_H, PREVIEW_MAX, PREVIEW_IN, PREVIEW_OUT, GAP

    if !g_hwnd
        return

    cp  := CurPos()
    mx  := cp.x
    my  := cp.y
    dx  := mx - g_mx0
    dy  := my - g_my0
    hg  := GAP // 2
    cwa := GetContentWorkArea()

    if (g_linked = "V") {
        divX   := Max(cwa.x + MIN_W, Min(cwa.r - MIN_W, g_divBase + dx))
        leftW  := divX - cwa.x - hg
        rightX := divX + hg
        rightW := cwa.r - rightX
        for item in g_lSide
            PosWinContent(item.hwnd, cwa.x, item.y, Max(MIN_W, leftW), item.h)
        for item in g_rSide
            PosWinContent(item.hwnd, rightX, item.y, Max(MIN_W, rightW), item.h)
        g_divV_map[g_deskKey] := divX
        return
    }
    if (g_linked = "H") {
        divY := Max(cwa.y + MIN_H, Min(cwa.b - MIN_H, g_divBase + dy))
        topH := divY - cwa.y - hg
        botY := divY + hg
        botH := cwa.b - botY
        for item in g_lSide
            PosWinContent(item.hwnd, item.x, cwa.y, item.w, Max(MIN_H, topH))
        for item in g_rSide
            PosWinContent(item.hwnd, item.x, botY, item.w, Max(MIN_H, botH))
        g_divH_map[g_deskKey] := divY
        return
    }

    if (g_mode = "resize") {
        x := g_wx0
        y := g_wy0
        w := g_ww0
        h := g_wh0
        if InStr(g_rdir, "e")
            w := Max(MIN_W, w + dx)
        if InStr(g_rdir, "s")
            h := Max(MIN_H, h + dy)
        if InStr(g_rdir, "w") {
            nw := Max(MIN_W, w - dx)
            x  := x + (w - nw)
            w  := nw
        }
        if InStr(g_rdir, "n") {
            nh := Max(MIN_H, h - dy)
            y  := y + (h - nh)
            h  := nh
        }
        PosWinContent(g_hwnd, x, y, w, h)
        return
    }

    if g_unmax {
        if (Abs(dx) <= 4 && Abs(dy) <= 4)
            goto SnapPreview
        g_unmax := false
        vis     := WinVisibleBounds(g_hwnd)
        g_wx0   := vis.x
        g_wy0   := vis.y
        g_mx0   := mx
        g_my0   := my
        dx      := 0
        dy      := 0
    }

    PosWinContent(g_hwnd, g_wx0 + dx, Max(cwa.y, g_wy0 + dy), g_ww0, g_wh0)

    SnapPreview:
    zone := CalcSnapZone(mx, my)

    if (zone != g_zone) {
        g_zone := zone
        if (zone != "") {
            r := SnapRect(ResolveSnapZone(zone))
            ShowOverlay(PreviewHwnd, r.x + 6, r.y + 6, r.w - 12, r.h - 12)
            g_prevVisible := true
        }
    }

    if (g_prevVisible && zone != "") {
        if (g_prevAlpha < PREVIEW_MAX) {
            g_prevAlpha := Min(PREVIEW_MAX, g_prevAlpha + PREVIEW_IN)
            DllCall("SetLayeredWindowAttributes",
                "Ptr", PreviewHwnd, "UInt", 0, "UChar", g_prevAlpha, "UInt", 2)
        }
    } else if (g_prevVisible && zone = "") {
        if (g_prevAlpha > 0) {
            g_prevAlpha := Max(0, g_prevAlpha - PREVIEW_OUT)
            DllCall("SetLayeredWindowAttributes",
                "Ptr", PreviewHwnd, "UInt", 0, "UChar", g_prevAlpha, "UInt", 2)
        } else {
            HideOverlay(PreviewHwnd)
            g_prevVisible := false
        }
    }
}

; ════════════════════════════════════════════════════════════════════════════
;  DRAG END
; ════════════════════════════════════════════════════════════════════════════
DragEnd() {
    global g_hwnd, g_mode, g_zone
    global g_prevAlpha, g_prevVisible, PreviewHwnd
    global g_linked, g_lSide, g_rSide, g_snapped

    HideOverlay(PreviewHwnd)
    DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)
    g_prevAlpha   := 0
    g_prevVisible := false

    if (g_linked = "V" || g_linked = "H") {
        for item in g_lSide
            g_snapped[item.hwnd] := item.zone
        for item in g_rSide
            g_snapped[item.hwnd] := item.zone
    } else if (g_mode = "move" && g_zone != "") {
        ApplySnap(g_hwnd, g_zone)
    }

    g_hwnd   := 0
    g_mode   := ""
    g_zone   := ""
    g_linked := ""
    g_lSide  := []
    g_rSide  := []
}

; ════════════════════════════════════════════════════════════════════════════
;  APPLY SNAP
; ════════════════════════════════════════════════════════════════════════════
ApplySnap(hwnd, requestedZone) {
    global g_snapped
    zone := ResolveSnapZone(requestedZone)
    if (zone = "max") {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 3)
        if g_snapped.Has(hwnd)
            g_snapped.Delete(hwnd)
        return
    }
    EvictContainedZones(zone)
    r := SnapRect(zone)
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
    PosWinContent(hwnd, r.x, r.y, r.w, r.h)
    g_snapped[hwnd] := zone
}

; ════════════════════════════════════════════════════════════════════════════
;  WIN+ARROW  KDE-STYLE SNAP CYCLING
; ════════════════════════════════════════════════════════════════════════════
PrepWAForWindow(hwnd) {
    global g_wa, g_deskKey
    vis       := WinVisibleBounds(hwnd)
    g_wa      := WorkAreaAt(vis.x + vis.w // 2, vis.y + vis.h // 2)
    g_deskKey := GetWindowDesktopKey(hwnd)
}

ApplySnapKbd(hwnd, zone) {
    RecordPreSnap(hwnd)
    ApplySnap(hwnd, zone)
    DllCall("SetForegroundWindow", "Ptr", hwnd)
}

MaximiseKbd(hwnd) {
    global g_preSnap, g_snapped
    RecordPreSnap(hwnd)
    if g_snapped.Has(hwnd)
        g_snapped.Delete(hwnd)
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 3)
    DllCall("SetForegroundWindow", "Ptr", hwnd)
}

SnapKeyLeft() {
    global g_snapped
    hwnd := WinGetID("A")
    if !hwnd
        return
    PrepWAForWindow(hwnd)
    zone   := g_snapped.Has(hwnd) ? g_snapped[hwnd] : ""
    minmax := WinGetMinMax("ahk_id " hwnd)
    if (minmax = 1) {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
        ApplySnapKbd(hwnd, "left")
    } else if (zone = "left") {
        ApplySnapKbd(hwnd, "tl")
    } else if (zone = "tl") {
        ApplySnapKbd(hwnd, "bl")
    } else if (zone = "bl") {
        RestoreFloating(hwnd)
        DllCall("SetForegroundWindow", "Ptr", hwnd)
    } else {
        ApplySnapKbd(hwnd, "left")
    }
}

SnapKeyRight() {
    global g_snapped
    hwnd := WinGetID("A")
    if !hwnd
        return
    PrepWAForWindow(hwnd)
    zone   := g_snapped.Has(hwnd) ? g_snapped[hwnd] : ""
    minmax := WinGetMinMax("ahk_id " hwnd)
    if (minmax = 1) {
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
        ApplySnapKbd(hwnd, "right")
    } else if (zone = "right") {
        ApplySnapKbd(hwnd, "tr")
    } else if (zone = "tr") {
        ApplySnapKbd(hwnd, "br")
    } else if (zone = "br") {
        RestoreFloating(hwnd)
        DllCall("SetForegroundWindow", "Ptr", hwnd)
    } else {
        ApplySnapKbd(hwnd, "right")
    }
}

SnapKeyUp() {
    global g_snapped
    hwnd := WinGetID("A")
    if !hwnd
        return
    PrepWAForWindow(hwnd)
    zone   := g_snapped.Has(hwnd) ? g_snapped[hwnd] : ""
    minmax := WinGetMinMax("ahk_id " hwnd)
    if (minmax = 1)
        return
    if (zone = "tl" || zone = "tr")
        MaximiseKbd(hwnd)
    else if (zone = "left")
        ApplySnapKbd(hwnd, "tl")
    else if (zone = "right")
        ApplySnapKbd(hwnd, "tr")
    else if (zone = "bl")
        ApplySnapKbd(hwnd, "left")
    else if (zone = "br")
        ApplySnapKbd(hwnd, "right")
    else
        MaximiseKbd(hwnd)
}

SnapKeyDown() {
    global g_snapped
    hwnd := WinGetID("A")
    if !hwnd
        return
    PrepWAForWindow(hwnd)
    zone   := g_snapped.Has(hwnd) ? g_snapped[hwnd] : ""
    minmax := WinGetMinMax("ahk_id " hwnd)
    if (minmax = 1) {
        ; Maximized → restore to floating
        RestoreFloating(hwnd)
        DllCall("SetForegroundWindow", "Ptr", hwnd)
    } else if (zone = "tl") {
        ApplySnapKbd(hwnd, "left")
    } else if (zone = "tr") {
        ApplySnapKbd(hwnd, "right")
    } else if (zone = "left") {
        ApplySnapKbd(hwnd, "bl")
    } else if (zone = "right") {
        ApplySnapKbd(hwnd, "br")
    } else if (zone = "bl" || zone = "br") {
        ; Already at the bottom — restore to floating
        RestoreFloating(hwnd)
        DllCall("SetForegroundWindow", "Ptr", hwnd)
    } else if (minmax = -1) {
        ; Minimized → restore
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
        DllCall("SetForegroundWindow", "Ptr", hwnd)
    } else {
        ; Floating → minimize
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 6)
    }
}

; ════════════════════════════════════════════════════════════════════════════
;  NATIVE TITLE-BAR DRAG SNAPPING
; ════════════════════════════════════════════════════════════════════════════
NativeDragTick() {
    global g_nativeDragHwnd, g_nativeDragActive, g_wa, g_deskKey
    global g_nativeZone, g_nativePrevAlpha, g_nativePrevVisible, PreviewHwnd
    global PREVIEW_MAX, PREVIEW_IN, PREVIEW_OUT, g_hwnd

    if (g_hwnd != 0)
        return
    if (!g_nativeDragActive || !g_nativeDragHwnd)
        return

    cp   := CurPos()
    mx   := cp.x
    my   := cp.y
    g_wa := WorkAreaAt(mx, my)
    zone := CalcSnapZone(mx, my)

    if (zone != g_nativeZone) {
        g_nativeZone := zone
        if (zone != "") {
            r := SnapRect(ResolveSnapZone(zone))
            ShowOverlay(PreviewHwnd, r.x + 6, r.y + 6, r.w - 12, r.h - 12)
            g_nativePrevVisible := true
        }
    }

    if (g_nativePrevVisible && zone != "") {
        if (g_nativePrevAlpha < PREVIEW_MAX) {
            g_nativePrevAlpha := Min(PREVIEW_MAX, g_nativePrevAlpha + PREVIEW_IN)
            DllCall("SetLayeredWindowAttributes",
                "Ptr", PreviewHwnd, "UInt", 0, "UChar", g_nativePrevAlpha, "UInt", 2)
        }
    } else if (g_nativePrevVisible && zone = "") {
        if (g_nativePrevAlpha > 0) {
            g_nativePrevAlpha := Max(0, g_nativePrevAlpha - PREVIEW_OUT)
            DllCall("SetLayeredWindowAttributes",
                "Ptr", PreviewHwnd, "UInt", 0, "UChar", g_nativePrevAlpha, "UInt", 2)
        } else {
            HideOverlay(PreviewHwnd)
            g_nativePrevVisible := false
        }
    }
}

NativeOnMoveStart(hHook, event, hwnd, idObj, idChild, tid, time) {
    global g_nativeDragHwnd, g_nativeDragActive
    global g_nativeZone, g_nativePrevAlpha, g_nativePrevVisible, PreviewHwnd
    global g_wa, g_deskKey, DRAG_MS, g_hwnd
    global g_nativeDragStartX, g_nativeDragStartY, g_nativeDragWasMax

    if (g_hwnd != 0)
        return
    if !hwnd
        return

    cls := WinGetClass("ahk_id " hwnd)
    if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd"
     || cls = "Shell_SecondaryTrayWnd" || cls = "DV2ControlHost")
        return

    if DllCall("IsIconic", "Ptr", hwnd)
        return

    cp := CurPos()

    ; Re-fire while LButton held = Windows just restored a maximized window.
    ; Reset overlay and zone; timer keeps running.
    if (g_nativeDragActive && hwnd = g_nativeDragHwnd) {
        g_nativeZone       := ""
        g_nativeDragWasMax := false
        g_wa               := WorkAreaAt(cp.x, cp.y)
        HideOverlay(PreviewHwnd)
        DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)
        g_nativePrevAlpha   := 0
        g_nativePrevVisible := false
        return
    }

    g_wa      := WorkAreaAt(cp.x, cp.y)
    g_deskKey := GetWindowDesktopKey(hwnd)

    g_nativeDragHwnd    := hwnd
    g_nativeDragActive  := true
    g_nativeZone        := ""
    g_nativePrevAlpha   := 0
    g_nativePrevVisible := false
    g_nativeDragStartX  := cp.x
    g_nativeDragStartY  := cp.y
    g_nativeDragWasMax  := (WinGetMinMax("ahk_id " hwnd) = 1)

    DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)
    SetTimer(NativeDragTick, DRAG_MS)
}

NativeOnMoveEnd(hHook, event, hwnd, idObj, idChild, tid, time) {
    global g_nativeDragHwnd, g_nativeDragActive
    global g_nativeZone, g_nativePrevAlpha, g_nativePrevVisible, PreviewHwnd
    global g_nativeDragStartX, g_nativeDragStartY, g_nativeDragWasMax
    global NATIVE_SNAP_MIN_DIST, g_hwnd, g_snapped

    if (hwnd != g_nativeDragHwnd)
        return

    ; LButton still held = unmaximize event pair, not the real drag end.
    if GetKeyState("LButton", "P") {
        HideOverlay(PreviewHwnd)
        DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)
        g_nativePrevAlpha   := 0
        g_nativePrevVisible := false
        g_nativeZone        := ""
        return
    }

    SetTimer(NativeDragTick, 0)
    HideOverlay(PreviewHwnd)
    DllCall("SetLayeredWindowAttributes", "Ptr", PreviewHwnd, "UInt", 0, "UChar", 0, "UInt", 2)
    g_nativePrevAlpha   := 0
    g_nativePrevVisible := false

    if (g_nativeZone != "") {
        cp   := CurPos()
        dist := Sqrt((cp.x - g_nativeDragStartX) ** 2 + (cp.y - g_nativeDragStartY) ** 2)
        skipSnap := (dist < NATIVE_SNAP_MIN_DIST)
                 || (g_nativeDragWasMax && ResolveSnapZone(g_nativeZone) = "max")
        if !skipSnap {
            if g_snapped.Has(hwnd)
                g_snapped.Delete(hwnd)
            ApplySnap(hwnd, g_nativeZone)
        }
    }

    g_nativeDragHwnd   := 0
    g_nativeDragActive := false
    g_nativeZone       := ""
}

InstallNativeDragHooks() {
    global g_cbStart, g_cbEnd, g_hookStart, g_hookEnd
    global EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, WINEVENT_OUTOFCONTEXT

    g_cbStart := CallbackCreate(NativeOnMoveStart, "F", 7)
    g_cbEnd   := CallbackCreate(NativeOnMoveEnd,   "F", 7)

    g_hookStart := DllCall("SetWinEventHook",
        "UInt", EVENT_SYSTEM_MOVESIZESTART,
        "UInt", EVENT_SYSTEM_MOVESIZESTART,
        "Ptr",  0,
        "Ptr",  g_cbStart,
        "UInt", 0,
        "UInt", 0,
        "UInt", WINEVENT_OUTOFCONTEXT,
        "Ptr")

    g_hookEnd := DllCall("SetWinEventHook",
        "UInt", EVENT_SYSTEM_MOVESIZEEND,
        "UInt", EVENT_SYSTEM_MOVESIZEEND,
        "Ptr",  0,
        "Ptr",  g_cbEnd,
        "UInt", 0,
        "UInt", 0,
        "UInt", WINEVENT_OUTOFCONTEXT,
        "Ptr")
}
InstallNativeDragHooks()

OnExit(CleanupHooks)
CleanupHooks(reason, code) {
    global g_hookStart, g_hookEnd
    if g_hookStart
        DllCall("UnhookWinEvent", "Ptr", g_hookStart)
    if g_hookEnd
        DllCall("UnhookWinEvent", "Ptr", g_hookEnd)
}

; ════════════════════════════════════════════════════════════════════════════
;  SYSTEM TRAY
; ════════════════════════════════════════════════════════════════════════════
TraySetIcon("shell32.dll", 13)

A_TrayMenu.Delete()
A_TrayMenu.Add("Alt-Drag Window Manager v8.0", MenuHandler)
A_TrayMenu.Disable("Alt-Drag Window Manager v8.0")
A_TrayMenu.Add()
A_TrayMenu.Add("🖱️  Alt + Left Click  →  Move Window",   MenuHandler)
A_TrayMenu.Disable("🖱️  Alt + Left Click  →  Move Window")
A_TrayMenu.Add("↔️  Alt + Right Click →  Resize Window", MenuHandler)
A_TrayMenu.Disable("↔️  Alt + Right Click →  Resize Window")
A_TrayMenu.Add("🪟  Title-bar drag    →  Snap Zones",    MenuHandler)
A_TrayMenu.Disable("🪟  Title-bar drag    →  Snap Zones")
A_TrayMenu.Add("⌨️  Win+←/→/↑/↓     →  Cycle Snap",    MenuHandler)
A_TrayMenu.Disable("⌨️  Win+←/→/↑/↓     →  Cycle Snap")
A_TrayMenu.Add()
A_TrayMenu.Add("Gap: " GAP "px", ToggleGap)
A_TrayMenu.Add("Reload", ReloadScript)
A_TrayMenu.Add("Exit", ExitScript)

MenuHandler(*) {
}

ToggleGap(ItemName, ItemPos, Menu) {
    global GAP
    static gaps := [0, 4, 8, 12, 16, 24, 32]
    currentIdx := 1
    for i, g in gaps {
        if (g = GAP) {
            currentIdx := i
            break
        }
    }
    GAP := gaps[Mod(currentIdx, gaps.Length) + 1]
    Menu.Rename(ItemName, "Gap: " GAP "px")
}

ReloadScript(*) {
    Reload()
}

ExitScript(*) {
    ExitApp()
}

A_IconTip := "Alt-Drag Window Manager v8.0`nAlt+LMB: Move  |  Alt+RMB: Resize`nTitle-bar: Snap  |  Win+←→↑↓: Cycle Snap"