import SwiftUI
import WindowLaneCore

/// One save/rename form and one selector shared by manager and settings.
struct WorkspacePresetControls: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var presets: WorkspacePresets
    var compact = false
    @State private var editing: PresetEdit?
    @State private var removed: WorkspacePreset?

    init(store: WorkspaceStore, compact: Bool = false) {
        self.store = store; presets = store.presets; self.compact = compact
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("已儲存工作區", selection: Binding<UUID?>(
                    get: { store.selectedPresetID },
                    set: { if let id = $0 { store.applyPreset(id) } })) {
                    Text(presets.items.isEmpty ? "尚未儲存" : "選擇排版…").tag(nil as UUID?)
                    ForEach(presets.items) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(store.isRunning || store.isBusy || presets.items.isEmpty)
                Button("儲存目前版面…") { editing = PresetEdit(id: nil, name: "", renaming: false) }
                    .laneGlassButton().disabled(store.ordered.isEmpty || store.isBusy || presets.readError != nil)
            }
            if !compact {
                Text("保留視窗順序、翻頁比例、主視窗寬度與螢幕。選擇後按「啟動工作區」套用；請先開啟原來的應用與文件。")
                    .font(.caption).foregroundStyle(Theme.muted)
                if let id = store.selectedPresetID, let selected = presets.items.first(where: { $0.id == id }) {
                    HStack {
                        Button("更新版面") { store.savePreset(name: selected.name, replacing: id) }
                            .disabled(store.isBusy || store.ordered.isEmpty)
                        Button("重新命名…") { editing = PresetEdit(id: id, name: selected.name, renaming: true) }
                        Button("刪除", role: .destructive) {
                            do { removed = try presets.delete(id); store.selectedPresetID = nil; store.message("已刪除「\(selected.name)」，可以復原。") }
                            catch { store.message(error.localizedDescription, error: true) }
                        }.disabled(store.isBusy)
                    }.buttonStyle(.bordered)
                }
                if let removed {
                    Button("復原刪除「\(removed.name)」") {
                        do { try presets.restore(removed); self.removed = nil; store.message("已復原「\(removed.name)」。") }
                        catch { store.message(error.localizedDescription, error: true) }
                    }.buttonStyle(.bordered)
                }
            }
            if let error = presets.readError { Text(error).font(.caption).foregroundStyle(.red) }
        }.sheet(item: $editing) { edit in
            WorkspacePresetNameView(store: store, edit: edit) { editing = nil }
        }
    }
}

private struct PresetEdit: Identifiable {
    let id: UUID?
    let name: String
    let renaming: Bool
}

private struct WorkspacePresetNameView: View {
    @ObservedObject var store: WorkspaceStore
    let edit: PresetEdit
    let close: () -> Void
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool
    init(store: WorkspaceStore, edit: PresetEdit, close: @escaping () -> Void) {
        self.store = store; self.edit = edit; self.close = close; _name = State(initialValue: edit.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.renaming ? "重新命名工作區" : "儲存目前工作區").font(.title3.weight(.semibold))
            TextField("工作區名稱", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("工作區名稱").onSubmit(save)
            Text(error ?? "例如：閱讀與筆記、設計工作。名稱最多 80 個字。")
                .font(.caption).foregroundStyle(error == nil ? Theme.muted : .red)
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button(edit.renaming ? "重新命名" : "儲存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 400).onAppear { focused = true }
    }
    private func save() {
        do {
            if edit.renaming, let id = edit.id {
                try store.presets.rename(id, to: name); store.message("已重新命名為「\(name)」。")
            } else { try store.savePresetThrowing(name: name, replacing: edit.id) }
            close()
        } catch { self.error = error.localizedDescription; focused = true }
    }
}
