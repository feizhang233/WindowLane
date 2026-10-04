import SwiftUI

private enum LaneSettingsPage: String, CaseIterable {
    case appearance, switching, permissions
    var title: String {
        switch self {
        case .appearance: return "外觀"
        case .switching: return "切換"
        case .permissions: return "權限"
        }
    }
}

/// A standalone settings window. Accepted preferences apply immediately.
struct BackgroundSettingsView: View {
    @ObservedObject private var store: WorkspaceStore
    @ObservedObject private var settings: BackgroundSettings
    @ObservedObject private var interaction: InteractionSettings
    @State private var page: LaneSettingsPage = .appearance
    private let onClose: () -> Void

    init(store: WorkspaceStore, onClose: @escaping () -> Void) {
        self.store = store
        self.settings = store.background
        self.interaction = store.interaction
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("設定").font(.title2.weight(.semibold))
                    Text("變更會自動保留。")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction).laneGlassButton(prominent: true)
            }
            Picker("設定分類", selection: $page) {
                ForEach(LaneSettingsPage.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case .appearance: appearance
                    case .switching: switching
                    case .permissions: permissions
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24).frame(minWidth: 540, minHeight: 520)
            .foregroundStyle(Theme.ink)
            .background(LaneWindowBackground(settings: settings, surface: .settings))
            .onAppear { store.refreshPermissions() }
            .onExitCommand(perform: onClose)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("透明度只影響背景，文字與控制項保持清晰。")
                .font(.callout).foregroundStyle(Theme.muted)
            transparencyControl(title: "應用與工作區透明度", value: settings.transparency,
                                setValue: settings.setTransparency)
            transparencyControl(title: "設定視窗透明度", value: settings.settingsTransparency,
                                setValue: settings.setSettingsTransparency)
            Divider()
            wallpaperPreview
            wallpaperControls
            HStack {
                Button("恢復預設背景") { settings.restoreDefault() }
                    .laneGlassButton().disabled(settings.isImporting || settings.isChoosingWallpaper)
                if settings.image != nil {
                    Button("移除壁紙") { settings.removeWallpaper() }
                        .laneGlassButton().disabled(settings.isImporting || settings.isChoosingWallpaper)
                }
                Spacer()
            }
            backgroundNotice
        }
    }

    private func transparencyControl(title: String, value: Double,
                                     setValue: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(Theme.muted)
            }
            Slider(value: Binding(get: { value }, set: setValue), in: 0...0.8)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value * 100).rounded())) 百分比")
        }
    }

    private var wallpaperPreview: some View {
        ZStack {
            LaneWindowBackground(settings: settings)
            Label(settings.mode == .frosted ? "工作區：半透明毛玻璃" : "工作區：自訂壁紙",
                  systemImage: "rectangle.3.group")
                .font(.headline).padding(12).laneGlass(radius: Theme.controlRadius)
        }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.line, lineWidth: 0.5))
    }

    private var wallpaperControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("背景樣式", selection: Binding(get: { settings.mode }, set: {
                if $0 == .wallpaper && settings.image == nil { settings.chooseWallpaper() }
                else { settings.setMode($0) }
            })) {
                Text("毛玻璃").tag(LaneBackgroundMode.frosted)
                Text("自訂壁紙").tag(LaneBackgroundMode.wallpaper)
            }.pickerStyle(.segmented).disabled(settings.isImporting || settings.isChoosingWallpaper)
            HStack(spacing: 12) {
                Image(systemName: "photo").foregroundStyle(Theme.muted)
                Text(settings.imageName ?? "尚未選擇壁紙").lineLimit(1).truncationMode(.middle)
                    .help(settings.imageName ?? "選擇本機圖片作為背景")
                Spacer()
                Button(settings.image == nil ? "選擇圖片…" : "更換圖片…") { settings.chooseWallpaper() }
                    .laneGlassButton().disabled(settings.isImporting || settings.isChoosingWallpaper)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("壁紙模糊")
                    Spacer()
                    Text("\(Int(settings.blur.rounded())) pt").monospacedDigit().foregroundStyle(Theme.muted)
                }
                Slider(value: Binding(get: { settings.blur }, set: { settings.setBlur($0) }), in: 0...60)
                    .accessibilityLabel("壁紙模糊")
                    .disabled(settings.mode != .wallpaper || settings.isImporting || settings.isChoosingWallpaper)
            }
        }
    }

    private var backgroundNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            if settings.isImporting { ProgressView().controlSize(.small) }
            else { Image(systemName: settings.isError ? "exclamationmark.circle" : "info.circle") }
            Text(settings.isImporting ? "正在處理圖片…" : settings.notice ?? "壁紙只儲存在這台 Mac，原圖保持完整。系統降低透明度或提高對比時，背景會改為實色。")
                .font(.caption).foregroundStyle(settings.isError ? Color.red : Theme.muted)
        }.frame(minHeight: 38, alignment: .topLeading)
    }

    private var switching: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("左右滑動滾輪切換視窗", isOn: Binding(
                get: { interaction.horizontalSwitchingEnabled },
                set: { interaction.setHorizontalSwitchingEnabled($0) }))
            Text("累積足夠的橫向滑動才切換，每次滑動最多切換一個視窗。垂直捲動不會觸發。")
                .font(.callout).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 16) {
                Picker("使用範圍", selection: Binding(
                    get: { interaction.scrollScope },
                    set: { interaction.setScrollScope($0) })) {
                    Text("工作區").tag(ScrollSwitchScope.workspace)
                    Text("僅切換條").tag(ScrollSwitchScope.rail)
                }.pickerStyle(.segmented)
                Text(interaction.scrollScope == .rail
                     ? "只在底部切換條上滑動，中央應用保留自己的橫向捲動。"
                     : "在目前視窗上左右滑動即可切換，應用本身也可能捲動內容。閱讀橫向表格或移動畫布時，可改為僅切換條。")
                    .font(.caption).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("切換閾值")
                        Spacer()
                        Text("\(Int(interaction.scrollThreshold.rounded()))")
                            .monospacedDigit().foregroundStyle(Theme.muted)
                    }
                    Slider(value: Binding(get: { interaction.scrollThreshold },
                                          set: { interaction.setScrollThreshold($0) }), in: 30...180, step: 1)
                        .accessibilityLabel("切換閾值")
                        .accessibilityValue("\(Int(interaction.scrollThreshold.rounded()))")
                    Text("數值越高，需要滑動的距離越長，越不容易誤觸。")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }.disabled(!interaction.horizontalSwitchingEnabled)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("已允許的權限收納在這裡；需要授權時，主介面也會顯示提示。")
                .font(.callout).foregroundStyle(Theme.muted)
            permissionStatus(title: "控制視窗", granted: store.trusted,
                             allowedText: "輔助使用已允許", actionText: "允許控制視窗",
                             explanation: "用於移動、切換和復原加入工作區的視窗。",
                             action: store.grantAccessibility)
            Divider()
            permissionStatus(title: "邊緣預覽", granted: store.captureAllowed,
                             allowedText: "螢幕錄製已允許", actionText: "允許邊緣預覽",
                             explanation: "選用；未允許時，邊緣顯示應用名稱卡片。影像只在本機記憶體顯示。",
                             action: store.grantCapture)
            Button("重新檢查權限") { store.refreshPermissions() }.laneGlassButton()
        }.onAppear { store.refreshPermissions() }
    }

    private func permissionStatus(title: String, granted: Bool, allowedText: String,
                                  actionText: String, explanation: String,
                                  action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(granted ? Theme.primary : Theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(granted ? allowedText : "尚未允許").font(.callout)
                Text(explanation).font(.caption).foregroundStyle(Theme.muted)
                if !granted { Button(actionText, action: action).laneGlassButton() }
            }
            Spacer(minLength: 0)
        }
    }
}
