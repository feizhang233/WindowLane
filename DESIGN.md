---
version: alpha
name: WindowLane
description: A native macOS window workspace with Liquid Glass controls and a floating horizontal rail.
colors:
  glassRim: "rgba(255, 255, 255, 0.35)"
typography:
  sans:
    fontFamily: "SF Pro, PingFang TC, system-ui, sans-serif"
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
rounded:
  DEFAULT: "18px"
  sm: "12px"
  lg: "24px"
spacing:
  unit: "8px"
  section: "24px"
components:
  button: {}
  window-card: {}
  workspace-rail: {}
---

# WindowLane Design System

## Overview

A macOS utility for reading, notes and reference work. The signature is a real horizontal lane: the selected window has generous space and its neighbors remain visibly within reach. Product UI, Traditional Chinese locale; no Japan-market assumption. Native control semantics and system permission prompts remain familiar. No marketing hero, dashboard charts, or ornamental gradients.

Runtime ownership: `Theme` in `Views.swift` owns adaptive monochrome emphasis, the glass rim and corner radii above. `GlassUI.swift` owns shared material and button presentation. SwiftUI native fonts use the system's Chinese fallback. DESIGN.md mirrors those accepted values; all custom views consume Theme rather than define local palettes. Text, surfaces, separators and disabled states use system semantic colors.

## Colors

Use a neutral monochromatic control layer. Theme.primary maps to Color.primary for adaptive emphasis; no fixed blue or app-wide accent tint is supplied. Secondary buttons use the native untinted glass style. Start and Done retain the prominent system style with monochrome emphasis; at most one prominent action is present in each view. Selected cards use a neutral outline, while the active rail item uses a subtle 8% primary fill plus semibold text. Translucent neutral glass takes color from the desktop and underlying content. The app follows macOS light/dark appearance. Theme.ink maps to Color.primary, muted to Color.secondary, canvas to NSColor.windowBackgroundColor, surface to NSColor.controlBackgroundColor, and line to NSColor.separatorColor. These adaptive system roles intentionally have no duplicated fixed RGB values. Managed applications retain their own appearance.

## Typography

SF rounded title at 28 pt, system body 13–15 pt, monospaced digits for window slots and shortcuts. Titles truncate only where the full window title is available in an accessibility label or tooltip. App names and actions remain visible.

## Layout

Manager minimum 880 × 650, padded 24 pt, scrollable window list. Settings is a separate 580 × 740 window, minimum 540 × 520; its header and native segmented categories remain visible while content scrolls. Main area 80–90% of one screen's usable width, default 84%. HorizontalScrollRouter owns horizontal input in the managed main window and rail; a rail-only option preserves application content scrolling. The external event monitor observes without suppressing the original event. Layout uses visibleFrame to avoid the menu bar and Dock.

## Elevation & Depth

Use native Liquid Glass for permission cards, occupied workspace slots, search, toolbar buttons and the floating rail on macOS 26+. GlassEffectContainer groups related effects. The manager window uses behind-window NSVisualEffectView translucency; discovered-window rows and empty states use quiet translucent surfaces. Row buttons keep the native bordered style inside a clipped ScrollView: refractive effects in a surrounding glass container must not escape the content viewport. Preview pixels stay unobscured, with glass only behind the arrow and identity label. macOS 14–25 use ultra-thin material and native bordered buttons. Reduce Transparency or increased contrast selects opaque, adaptive surfaces with visible borders. A short nonanimated input shield prepares focus handoff; direct switching has no snapshot-slide animation.

## Shapes

18 pt continuous cards, 12 pt controls, 24 pt workspace rail. SF Symbols are used with text or explicit accessibility labels.

## Components

Native SwiftUI Buttons own focus/pressed/disabled states. One status region shows actionable errors. Search has an explicit clear action. The window list supports drag ordering and left/right buttons. Permission actions open system settings; an ungranted permission disables only the feature requiring it. Preview images are last captured snapshots and labeled accordingly. No screenshot is saved to disk by the app.

Shared presentation: laneGlass applies untinted native regular glass and a fine rim, with a stronger adaptive monochrome border for selection. laneGlassButton selects untinted system glass for secondary actions and monochrome glassProminent for the single primary action, with older-system fallback. LaneWindowBackground owns window translucency. No decorative blur is applied to document images. Native material rendering must be inspected on screen; offscreen NSBitmapImageRep smoke images cannot establish the final compositor appearance.

BackgroundSettings is the single owner for background preferences. Default: behind-window frosted material at 35% transparency. Application/manager/workspace and settings-window transparency are independently saved and bounded to 0–80%, selected through LaneWindowBackground's surface role. Both default to 35%; older preferences retain the application's prior value and use the default for settings. A local wallpaper may replace this material; scale to fill while preserving aspect ratio, crop overflow and overscan before applying an adjustable 0–60 pt blur. Controls and document pixels remain independent. Accessibility overrides use an opaque semantic surface without discarding the saved background choice. A standalone settings window contains Appearance, Switching and Permissions categories using native segmented controls and labeled sliders; its preview is decorative. Preferences apply immediately and persist locally. Reset selects default frosted background and both transparency defaults while retaining the last image for reuse; Remove Wallpaper deletes only the managed copy. Never change a user's source image. Image selection and import each block duplicate requests.

Granted permissions appear only in Settings; the manager shows cards only for missing permissions and reintroduces them when access is revoked. Settings remains available during a workspace. Closing it attempts to restore the active window's input focus.

InteractionSettings owns enabled state, horizontal threshold (30–180, default 80) and workspace/rail-only scope. HorizontalScrollGate accumulates deliberate input, resets on direction reversal or 250 ms idle, ignores vertical/momentum input, limits phase gestures to one switch and applies a 450 ms cooldown. Busy/disabled input is discarded, never queued. A global trigger requires the exact active AX focused window and excludes modal sheets; matching only an application's PID is insufficient.

Edge previews preserve each snapshot's original logical size in points. Keep the aspect ratio and scale down only when the snapshot is taller than the preview area; never enlarge a small snapshot to fill the panel. Crop horizontally to the edge panel, showing the inward-facing edge of the neighboring window. If the image is shorter than the panel, reveal the shared workspace backdrop in the remaining area; do not tile or stretch the wallpaper inside individual previews.

Capture uses ScreenCaptureKit's `filter.contentRect × filter.pointPixelScale` for pixel dimensions, rounded up. The image retains the window's logical point size separately, preserving native pixel density without changing its displayed scale. Pixel dimensions and logical-size checks verify this sizing contract; actual readability and image clarity require visual confirmation.

Selection uses an adaptive border, index, semibold text and a subtle neutral fill. Native focus rings and system-owned selection can retain the user's macOS accent. Version 0.2.1 defaults to direct native raise/focus switching without a fixed animation delay. Start prepares every managed window at the same main frame, unminimized and stacked. Normal selection changes focus only; it does not re-place or park the previous window. Update the active slot after actual focus succeeds, then refresh the previous window's optional snapshot in a background task. Expansion and its reversal resize the entire stack once, so later switches remain geometry-free. Managed windows retain their own rendering; transparent content may reveal a real window underneath.

The nonanimated input shield is released before asking for actual native focus. Stop invalidates operation tokens, cancels old operations and previews, waits for them to unwind, then independently restores every saved original frame and minimized state with new work blocked. App termination waits for restoration. Failed restoration or a corrupt journal stays visible and is retained for retry or explicit manual acknowledgement. Global shortcuts are shown in the manager and tooltips. Screen removal stops the workspace and restores reachable windows.

## Restoration and verification

Recovery is a separate capability from adding a new window. WindowBackend.recoveryCandidate reads the original application's windows without requiring discovery-time resize eligibility. It checks the saved process, bundle and launch identity; unavailable identity or AX data preserves the record. The current session's AX identity is preferred. Across a restart, a stored WindowServer ID must still belong to the saved process and have one complete, stable AX geometry correspondence. Titles alone never replace identity. Only verified restoration, confirmed original-process termination/replacement, or explicit manual acknowledgement removes a record.

Restore the original frame rather than silently accepting an application's screen clamp. A previously accepted frame may extend outside the display. Conservative temporary staging for such a frame must preserve the saved target and retain final AX/WindowServer verification; unsupported placement remains a visible failure with its record intact.

Version 0.2.1 direct-switch verification is recorded at the top of verification/TESTING.md; final counts, native UI, geometry/minimize-write deltas, focus latency and packaging remain pending. Version 0.2.0's native/background/external reports, UI and build manifest are archived as *-stability-v020.json. Those results establish the earlier stability/settings update, not the new direct-switch behavior. Neutral glass, wallpaper and independent transparency preferences retain the accepted design above.

## Do's and Don'ts

- Do preserve window identity, document content and input state.
- Do distinguish removing a window from closing it.
- Do make demo mode visibly different from managing other applications.
- Don't promise true cross-process embedding, live video previews, or unsupported full-screen windows.
- Don't make permissions a prerequisite for trying the demonstration.

## Apple guidance and neutral control direction

User-approved direction (2026-10-04): keep the default frosted background and custom wallpaper capability, reduce blue control backgrounds, and follow Apple's native visual hierarchy. Apple's [Color HIG](https://developer.apple.com/design/human-interface-guidelines/color) describes a monochromatic default for Liquid Glass labels and recommends reserving tint for elements that need emphasis, avoiding colored backgrounds on multiple controls. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) recommends limiting prominent actions. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) distinguishes the functional glass layer from standard background materials. This app applies those principles using untinted secondary buttons and adaptive monochrome primary actions; user-selected wallpaper remains content and may have its own colors.
