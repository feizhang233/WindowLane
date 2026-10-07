---
version: alpha
name: WindowLane
description: A native macOS window workspace with named layouts, continuous partial paging, real dual panes and Liquid Glass controls.
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

A macOS utility for reading, notes and reference work. The signature is a real horizontal lane: the selected window has generous space and a partial turn leaves two original application windows available side by side. Named layouts preserve this arrangement for later selection. Product UI, Traditional Chinese locale; no Japan-market assumption. Native control semantics and system permission prompts remain familiar. No marketing hero, dashboard charts, or ornamental gradients.

Runtime ownership: `Theme` in `Views.swift` owns adaptive monochrome emphasis, the glass rim and corner radii above. `GlassUI.swift` owns shared material and button presentation. SwiftUI native fonts use the system's Chinese fallback. DESIGN.md mirrors those accepted values; all custom views consume Theme rather than define local palettes. Text, surfaces, separators and disabled states use system semantic colors.

## Colors

Use a neutral monochromatic control layer. Theme.primary maps to Color.primary for adaptive emphasis; no fixed blue or app-wide accent tint is supplied. Secondary buttons use the native untinted glass style. Start and Done retain the prominent system style with monochrome emphasis; at most one prominent action is present in each view. Selected cards use a neutral outline, while the active rail item uses a subtle 8% primary fill plus semibold text. Translucent neutral glass takes color from the desktop and underlying content. The app follows macOS light/dark appearance. Theme.ink maps to Color.primary, muted to Color.secondary, canvas to NSColor.windowBackgroundColor, surface to NSColor.controlBackgroundColor, and line to NSColor.separatorColor. These adaptive system roles intentionally have no duplicated fixed RGB values. Managed applications retain their own appearance.

## Typography

SF rounded title at 28 pt, system body 13–15 pt, monospaced digits for window slots and shortcuts. Titles truncate only where the full window title is available in an accessibility label or tooltip. App names and actions remain visible.

## Layout

Manager minimum 880 × 650, padded 24 pt, scrollable window list. Settings is a separate 580 × 740 window, minimum 540 × 520; its header and native segmented categories remain visible while content scrolls. Appearance, Workspace, Switching and Permissions are the four categories. Single-page width (80–90%, default 84%) and display selection belong to Workspace settings, remain disabled while running and persist locally; remove these sliders from the main management lane. Layout uses visibleFrame to avoid the menu bar and Dock.

WorkspaceLayout owns full-page frames; BookPageLayout owns a fractional position and two adjacent real panes within the usable content area. Position 0.5 produces equal panes when both application minimums permit it. Other fractions retain their position after release, with minimum pane widths rather than arbitrarily narrow native windows. Near-integer tolerance is only a numerical endpoint normalization, not a release-to-nearest-page rule. The rail has an explicit half-page action. Each pane uses its application's observed minimum width; constrain the pane boundary while keeping the selected fraction. If a layout is rejected, restore the last accepted real arrangement and keep the workspace running. Both panes must sit above other managed windows after focus handoff; a geometry-only match cannot prove that an inactive pane is exposed. HorizontalScrollRouter owns horizontal input in the actual focused pane and rail. A rail-only option preserves application content scrolling; the external event monitor observes without suppressing the original event.

## Elevation & Depth

Use native Liquid Glass for permission cards, occupied workspace slots, search, toolbar buttons and the floating rail on macOS 26+. GlassEffectContainer groups related effects. The manager window uses behind-window NSVisualEffectView translucency; discovered-window rows and empty states use quiet translucent surfaces. Row buttons keep the native bordered style inside a clipped ScrollView: refractive effects in a surrounding glass container must not escape the content viewport. Preview pixels stay unobscured, with glass only behind the arrow and identity label. macOS 14–25 use ultra-thin material and native bordered buttons. Reduce Transparency or increased contrast selects opaque, adaptive surfaces with visible borders. A short nonanimated input shield prepares focus handoff. An optional fresh outgoing snapshot then slides aside with subtle perspective to reveal the already-focused native destination; motion and its edge shadow are clipped to the main frame, leaving the neutral glass rail and previews unchanged.

## Shapes

18 pt continuous cards, 12 pt controls, 24 pt workspace rail. SF Symbols are used with text or explicit accessibility labels.

## Components

Native SwiftUI Buttons own focus/pressed/disabled states. One status region shows actionable errors. Search has an explicit clear action. The window list supports drag ordering and left/right buttons. Permission actions open system settings; an ungranted permission disables only the feature requiring it. Preview images are last captured snapshots and labeled accordingly. No screenshot is saved to disk by the app.

Shared presentation: laneGlass applies untinted native regular glass and a fine rim, with a stronger adaptive monochrome border for selection. laneGlassButton selects untinted system glass for secondary actions and monochrome glassProminent for the single primary action, with older-system fallback. LaneWindowBackground owns window translucency. No decorative blur is applied to document images. Native material rendering must be inspected on screen; offscreen NSBitmapImageRep smoke images cannot establish the final compositor appearance.

BackgroundSettings is the single owner for background preferences. Default: behind-window frosted material at 35% transparency. The manager and settings window share one application transparency value; the workspace backdrop and its decorative preview use an independently saved workspace value. Both are bounded to 0–80% and default to 35%. BackgroundSettings owns the values, and every LaneWindowBackground consumer explicitly selects the application or workspace surface role. When migrating older preferences, both groups inherit the prior application/workspace value; the old settings-window-only value is retired. Wallpaper, blur and all other preferences are preserved. A local wallpaper may replace this material; scale to fill while preserving aspect ratio, crop overflow and overscan before applying an adjustable 0–60 pt blur. Controls and document pixels remain independent. Accessibility overrides use an opaque semantic surface without discarding the saved background choice. Appearance settings own these labeled sliders and the decorative workspace preview. Preferences apply immediately and persist locally. Reset selects default frosted background and both transparency defaults while retaining the last image for reuse; Remove Wallpaper deletes only the managed copy. Never change a user's source image. Image selection and import each block duplicate requests.

Granted permissions appear only in Settings; the manager shows cards only for missing permissions and reintroduces them when access is revoked. Settings remains available during a workspace. Closing it attempts to restore the active window's input focus.

WorkspacePresetControls is the shared selector and naming form in the manager and Workspace settings; names require 1–80 characters. WorkspacePresets adapts WorkspacePresetRepository's atomic local JSON, bounded to 24 presets with six windows each. Save records order, active slot, single-page width, display and fractional position. Update keeps the preset identity; rename edits only its name; deletion offers an undo that restores the original record. Applying requires every saved window to resolve before replacing the current selection. Prefer the exact process/window/launch identity; after restart allow only a unique exact bundle-and-title match, never a similar-title guess or the first ambiguous result. Loading a preset never reopens applications or documents. Missing windows keep the user's current lane and explain what to open. A missing display uses the current display with an explanation. Corrupt, future-version and failed-write cases preserve accepted data; normal screenshots are never included in the archive.

InteractionSettings owns enabled state, mode (continuous by default or stepped), horizontal distance/threshold (30–180, default 80) and workspace/rail-only scope. ContinuousScrollPaging maps deliberate input distance to a fractional position, supports reversal and crossing multiple pages, ignores vertical/momentum input and preserves the exact fraction on gesture end or a 160 ms idle for wheels without phases. During a continuous preview, native geometry remains at its accepted state; commit applies one validated real layout after release. Cancel restores the previously accepted fraction. Ordinary busy/disabled input is discarded, never queued; an in-progress continuous gesture may continue while its preview is busy. HorizontalScrollGate retains the stepped alternative: direction reversal or 250 ms idle resets accumulation, phase gestures trigger once and ordinary wheels use a 450 ms cooldown. A global trigger requires the exact focused managed window and excludes modal sheets; matching only an application's PID is insufficient. A held native drag suspends wheel paging.

ContinuousPagePresentation owns the clipped, nonactivating memory-snapshot preview during side-wheel input. Its position follows input without detents or an automatic nearest-page finish. Cached adjacent snapshots remain previews; a fresh active-window snapshot may improve the outgoing image. Missing images use clearly named placeholders. Reduce Motion bypasses the moving snapshot while preserving the selected real layout on release. Clicking, beginning a drag or changing the frontmost application cancels an uncommitted preview and returns to the accepted layout. Committing raises both real panes, chooses actual keyboard focus, removes the snapshot cover and leaves both original applications available to pointer input. Editing and drops occur in the real panes after this native commit; the temporary image layers do not own those interactions.

DragTransferRouter and EdgeDropHostingView provide navigation during an existing native drag: a valid advertised pasteboard type may dwell on an available edge for 450 ms, revealing the adjacent original window without replacing the source application's drag session. One stationary edge visit triggers at most once. The edge view returns no drop acceptance and does not read payload bytes, resolve file promises, copy files or synthesize a new drag. The user moves into the exposed native destination and drops there; source and destination support determine acceptance. Stop, drag end and cancellation reset hover state. Verify actual file/image transfers separately from router state, frame checks or window visibility; no blanket cross-application guarantee follows from two-pane geometry.

Edge previews preserve each snapshot's original logical size in points. Keep the aspect ratio and scale down only when the snapshot is taller than the preview area; never enlarge a small snapshot to fill the panel. Crop horizontally to the edge panel, showing the inward-facing edge of the neighboring window. If the image is shorter than the panel, reveal the shared workspace backdrop in the remaining area; do not tile or stretch the wallpaper inside individual previews.

Capture uses ScreenCaptureKit's `filter.contentRect × filter.pointPixelScale` for pixel dimensions, rounded up. The image retains the window's logical point size separately, preserving native pixel density without changing its displayed scale. Pixel dimensions and logical-size checks verify this sizing contract; actual readability and image clarity require visual confirmation.

Selection uses an adaptive border, index, semibold text and a subtle neutral fill. Native focus rings and system-owned selection can retain the user's macOS accent. A single-page Start prepares every managed window at the same main frame, unminimized and stacked; a fractional saved layout prepares and raises both native panes. Normal stepped selection from a prepared single-page frame changes real-window focus only; it does not re-place or park the previous window. Leaving a split view first restores the common geometry. Before native focus handoff, the coordinator may obtain a fresh outgoing-window snapshot, with a 100 ms wait budget for external ScreenCaptureKit capture. For the stepped effect, never substitute an old thumbnail or a screenshot of the incoming window. Missing, slow or already-busy capture, an incompatible logical image size, or Reduce Motion skips the effect and proceeds with direct focus.

After actual focus succeeds, update the active slot and let PageTurnTransition reveal the real destination with a 280 ms full-width slide: forward moves the outgoing page left, backward moves it right. Its Core Animation transform reaches a subtle 6-degree perspective tilt, with a narrow neutral edge shadow and eased settling. PageTurnTransition owns these shared motion values and the nonactivating overlay; the main-frame clip prevents spill into adjacent UI. Keep selection busy until this presentation ends, then update the rail and refresh the previous window's optional edge preview in a background task. Expansion and its reversal resize the entire stack once, so later prepared single-page stepped switches remain geometry-free. Managed windows retain their own rendering; transparent content may reveal a real window underneath.

The nonanimated input shield is released before asking for actual native focus. The stepped page overlay absorbs pointer and scrolling events while visible, but cannot become key or main; keyboard input belongs to the confirmed destination throughout the visual reveal. Reduce Motion is checked before preparing and starting the animation. Stop synchronously removes both kinds of page overlay, releases their images and completion waiters, resets drag navigation and gesture state, invalidates operation tokens, cancels old operations and previews, waits for them to unwind, then independently restores every saved original frame and minimized state with new work blocked. Fractional commits never overwrite those originals. Generation checks prevent late animation completions from affecting a later switch. App termination waits for restoration. Failed restoration or a corrupt journal stays visible and is retained for retry or explicit manual acknowledgement. Global shortcuts are shown in the manager and tooltips. Screen removal stops the workspace and restores reachable windows.

## Restoration and verification

Recovery is a separate capability from adding a new window. WindowBackend.recoveryCandidate reads the original application's windows without requiring discovery-time resize eligibility. It checks the saved process, bundle and launch identity; unavailable identity or AX data preserves the record. The current session's AX identity is preferred. Across a restart, a stored WindowServer ID must still belong to the saved process and have one complete, stable AX geometry correspondence. Titles alone never replace identity. Only verified restoration, confirmed original-process termination/replacement, or explicit manual acknowledgement removes a record.

Restore the original frame rather than silently accepting an application's screen clamp. A previously accepted frame may extend outside the display. Conservative temporary staging for such a frame must preserve the saved target and retain final AX/WindowServer verification; unsupported placement remains a visible failure with its record intact.

Current verification is recorded at the top of verification/TESTING.md. Named persistence, fractional layout acceptance, cancellation, two-pane exposure and native drag delivery require their own evidence; earlier stepped-switch reports cannot establish these behaviors. Native focus latency, request-to-presentation latency, geometry/minimize-write deltas, animation fallback paths and packaging also remain distinct measures. The 280 ms stepped duration is not a claim about total cross-application switching time; fractional geometry changes have their own cost. Version 0.2.0's reports remain archived as *-stability-v020.json. Neutral glass, wallpaper, application/settings shared transparency and independent workspace transparency retain the accepted design above.

## Do's and Don'ts

- Do preserve window identity, document content and input state.
- Do distinguish removing a window from closing it.
- Do make demo mode visibly different from managing other applications.
- Don't promise true cross-process embedding, live video previews, or unsupported full-screen windows.
- Don't make permissions a prerequisite for trying the demonstration.

## Apple guidance and neutral control direction

User-approved direction (2026-10-04): keep the default frosted background and custom wallpaper capability, reduce blue control backgrounds, and follow Apple's native visual hierarchy. Apple's [Color HIG](https://developer.apple.com/design/human-interface-guidelines/color) describes a monochromatic default for Liquid Glass labels and recommends reserving tint for elements that need emphasis, avoiding colored backgrounds on multiple controls. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons) recommends limiting prominent actions. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) distinguishes the functional glass layer from standard background materials. This app applies those principles using untinted secondary buttons and adaptive monochrome primary actions; user-selected wallpaper remains content and may have its own colors.
