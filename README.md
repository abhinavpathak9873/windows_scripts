# Windows Virtual Desktop Manager
An AutoHotkey v2 script for managing Windows virtual desktops with keyboard shortcuts. Supports switching desktops, moving windows between desktops, auto-centering new windows, and more.

## Requirements

- [AutoHotkey v2](https://www.autohotkey.com/)
- [VirtualDesktopAccessor.dll](https://github.com/Ciantic/VirtualDesktopAccessor) — place it in the same directory as the script

## Installation

1. Install AutoHotkey v2
2. Download `VirtualDesktopAccessor.dll` and place it next to `desktop.ahk`
3. Run `desktop.ahk` — it will prompt for admin elevation via UAC on first launch

## Features

- **Auto-elevation** — the script always runs as administrator
- **Switch desktops** — jump to any desktop instantly
- **Move windows** — send the active window to another desktop and follow it
- **Smart focus** — when switching desktops, focus is restored to the topmost window on the target desktop; if the desktop is empty, focus resets to the desktop itself
- **Auto-center** — every new window that opens is automatically centered on screen
- **Quick close** — close the active window with a hotkey
- **Launch terminal** — open Windows Terminal instantly

## Hotkeys

| Hotkey | Action |
|---|---|
| `Alt + 1–9` | Switch to desktop 1–9 |
| `Alt + Shift + 1–9` | Move active window to desktop 1–9 and follow it |
| `Alt + Shift + Q` | Close the active window |
| `Ctrl + Alt + T` | Open Windows Terminal |

## Notes

- Desktops are zero-indexed internally (desktop 1 = index 0), but the hotkeys map intuitively: `Alt+1` goes to the first desktop, `Alt+2` to the second, and so on.
- The script uses a 150ms delay after switching desktops to allow Windows to settle before setting focus. If focus is still inconsistent on your machine, try increasing the `Sleep` values in `SwitchDesktop` and `MoveAndSwitch`.
- Auto-centering skips minimized, maximized, and untitled system windows. Windows are only centered once — minimizing and restoring will not re-center them.
- The script hooks into system-wide window events, which is why admin privileges are required for it to work correctly across all applications.
