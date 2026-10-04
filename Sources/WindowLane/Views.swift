import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Canonical palette mirrored in DESIGN.md. Managed applications retain their own themes.
enum Theme {
    // Adaptive monochrome emphasis. Native focus rings keep the user's system accent.
    static let primary = Color.primary
    static let ink = Color.primary
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let muted = Color.secondary
    static let line = Color(nsColor: .separatorColor)
    static let glassRim = Color.white.opacity(0.35)
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let railRadius: CGFloat = 24
}

struct ManagerView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var query = ""
    @State private var draggedID: String?
    @State private var confirmManualRecovery = false
    var filtered: [WindowCandidate] { store.candidates.filter { query.isEmpty || "\($0.appName) \($0.title)".localizedCaseInsensitiveContains(query) } }
    var body: some View {
        LaneGlassGroup(spacing: 6) {
        VStack(alignment:.leading,spacing:20) {
            HStack(alignment:.center) {
                Image(systemName:"rectangle.3.group").font(.system(size:32,weight:.medium)).foregroundStyle(Theme.primary)
                VStack(alignment:.leading,spacing:4) {
                    Text("WindowLane").font(.system(size:28,weight:.semibold,design:.rounded))
                    Text("把工作排成一條線。專注當下，下一個視窗就在旁邊。")
                        .font(.system(size:13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { store.onShowSettings?() } label: { Label("設定", systemImage: "gearshape") }
                    .laneGlassButton()
                if store.isDemo { Text("示範模式").font(.caption.weight(.semibold)).padding(.horizontal,10).padding(.vertical,6).laneGlass(radius:20) }
                Button("開啟示範") { store.loadDemo() }.laneGlassButton().disabled(store.isBusy)
            }
            if !store.trusted || !store.captureAllowed {
                HStack(spacing:12) {
                    if !store.trusted {
                        permissionCard(title:"控制視窗",subtitle:"允許移動、切換和復原視窗",granted:false,action:store.grantAccessibility)
                    }
                    if !store.captureAllowed {
                        permissionCard(title:"邊緣預覽",subtitle:"選用；未允許時顯示名稱卡片",granted:false,action:store.grantCapture)
                    }
                }
            }
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("工作區").font(.headline)
                    Text("\(store.order.ids.count) / 6").font(.system(.caption,design:.monospaced)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("拖曳排序，或使用左右箭頭").font(.caption).foregroundStyle(Theme.muted)
                    Button { store.addFrontmost() } label: { Label("加入目前視窗",systemImage:"plus") }
                        .laneGlassButton()
                        .disabled(!store.trusted || store.isRunning || store.isBusy || store.order.ids.count >= 6)
                }
                HStack(spacing:9) {
                    ForEach(0..<6,id:\.self) { index in
                        if index < store.ordered.count {
                            let item = store.ordered[index]
                            slot(item,index:index)
                                .onDrag { draggedID = item.id; return NSItemProvider(object:item.id as NSString) }
                                .onDrop(of:[UTType.text],isTargeted:nil) { providers in
                                    guard !providers.isEmpty, let id = draggedID else { return false }
                                    store.move(id,to:index); draggedID = nil; return true
                                }
                        } else {
                            VStack(spacing:8) {
                                Text(String(format:"%02d",index+1)).font(.system(size:18,weight:.light,design:.monospaced))
                                Text("空位").font(.caption)
                            }.foregroundStyle(Theme.muted).frame(maxWidth:.infinity).frame(height:146)
                                .background(Theme.surface.opacity(0.18),in:RoundedRectangle(cornerRadius:Theme.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius:Theme.cardRadius).strokeBorder(Theme.line,style:StrokeStyle(lineWidth:1,dash:[4,4])))
                        }
                    }
                }
            }
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:4) {
                    Text("主視窗寬度 \(Int(store.ratio * 100))%").font(.caption.weight(.medium))
                    Slider(value:$store.ratio,in:0.80...0.90,step:0.01).frame(width:180).accessibilityLabel("主視窗寬度")
                        .disabled(store.isRunning || store.isBusy)
                }
                Divider().frame(height:32)
                Picker("螢幕",selection:$store.screenIndex) {
                    ForEach(Array(NSScreen.screens.enumerated()),id:\.offset) { index,screen in
                        Text(screen.localizedName).tag(index)
                    }
                }.frame(maxWidth:250).disabled(store.isRunning || store.isBusy)
                Spacer()
                Button { store.start() } label: {
                    HStack { if store.isBusy { ProgressView().controlSize(.small) }; Text("啟動工作區"); Image(systemName:"arrow.right") }
                        .frame(minWidth:112)
                }.laneGlassButton(prominent:true).controlSize(.large)
                    .disabled(store.ordered.isEmpty || store.isBusy || (!store.isDemo && !store.trusted) || !store.pendingRecovery.isEmpty || store.recoveryReadFailed)
            }
            Divider()
            HStack {
                Text("已開啟的視窗").font(.headline)
                Spacer()
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("搜尋應用或視窗名稱",text:$query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜尋") }
                }.padding(10).frame(width:240).laneGlass(radius:Theme.controlRadius)
                Button { store.refreshWindows() } label: { Label("重新整理",systemImage:"arrow.clockwise") }.laneGlassButton().disabled(store.isBusy)
            }
            ScrollView {
                LazyVStack(spacing:6) {
                    if !store.trusted {
                        emptyState("先允許輔助使用，或直接開啟示範。",detail:"WindowLane 使用系統提供的視窗控制功能；不會讀取或修改文件內容。",symbol:"macwindow.badge.plus")
                    } else if filtered.isEmpty {
                        emptyState(query.isEmpty ? "尚未找到可管理的視窗" : "沒有符合的視窗",detail:"請開啟一般視窗並離開全螢幕模式，再按重新整理。",symbol:"rectangle.on.rectangle.slash")
                    } else {
                        ForEach(filtered) { item in
                            HStack(spacing:12) {
                                AppIcon(image:item.icon,size:28)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(item.title).lineLimit(1).help(item.title)
                                    Text(item.appName).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                let added = store.entries[item.id] != nil
                                Button(added ? "已加入" : "加入") { store.add(item) }
                                    .buttonStyle(.bordered)
                                    .disabled(added || store.order.ids.count >= 6 || store.isBusy)
                            }.padding(10).background(Theme.surface.opacity(0.45),in:RoundedRectangle(cornerRadius:Theme.controlRadius))
                        }
                    }
                }.padding(.trailing,4)
            }.frame(minHeight:90,maxHeight:.infinity).clipped()
            if !store.pendingRecovery.isEmpty || store.recoveryReadFailed {
                HStack {
                    Label(store.recoveryReadFailed ? "復原記錄需要確認" : "有 \(store.pendingRecovery.count) 個視窗等待復原",systemImage:"arrow.uturn.backward.circle")
                    Spacer()
                    Button("查看記錄") { store.revealRecoveryRecord() }
                    Button("已手動復原") { confirmManualRecovery = true }.disabled(store.isBusy)
                    Button("重試復原") { store.recover() }.disabled(!store.trusted || store.isBusy || store.recoveryReadFailed)
                }.font(.callout).padding(10).background(Color.orange.opacity(0.10),in:RoundedRectangle(cornerRadius:8))
            }
            HStack(alignment:.top,spacing:8) {
                Image(systemName:store.isError ? "exclamationmark.circle" : "info.circle")
                Text(store.status).lineLimit(3).textSelection(.enabled)
                Spacer()
            }.font(.caption).foregroundStyle(store.isError ? Color.red : Theme.muted).frame(minHeight:28,alignment:.topLeading)
            HStack {
                Text("⌃⌥ ← / → 切換    ·    ⌃⌥ 1–6 跳轉    ·    ⌃⌥ ↩ 放大    ·    ⌃⌥ Esc 退出")
                Spacer()
                Text("預覽保留於記憶體")
            }.font(.system(size:10)).foregroundStyle(Theme.muted)
        }
        .padding(24).foregroundStyle(Theme.ink)
        }.background(LaneWindowBackground(settings: store.background))
        .frame(minWidth:880,minHeight:650)
        .onAppear { store.refreshWindows() }
        .alert("已手動恢復所有視窗？",isPresented:$confirmManualRecovery) {
            Button("取消",role:.cancel) {}
            Button("確認完成") { store.acknowledgeManualRecovery() }
        } message: { Text("確認後會清除等待復原的記錄；應用視窗保持原狀。") }
    }
    private func permissionCard(title:String,subtitle:String,granted:Bool,action:@escaping ()->Void) -> some View {
        HStack(spacing:10) {
            Image(systemName:granted ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(granted ? Theme.primary : Theme.muted).font(.title3)
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:13,weight:.semibold))
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !granted { Button("允許",action:action).accessibilityLabel("允許\(title)") }
        }.padding(14).frame(maxWidth:.infinity).laneGlass()
    }
    private func slot(_ item:ManagedWindow,index:Int) -> some View {
        VStack(spacing:8) {
            Button { store.select(item.id) } label: {
                VStack(spacing:7) {
                    HStack { Text(String(format:"%02d",index+1)).font(.system(.caption,design:.monospaced)); Spacer(); Image(systemName:"line.3.horizontal").font(.caption) }.foregroundStyle(Theme.muted)
                    AppIcon(image:item.icon,size:30)
                    Text(item.appName).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(item.title).font(.system(size:10)).lineLimit(1).foregroundStyle(Theme.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("第 \(index+1) 個：\(item.appName)，\(item.title)").help(item.title)
            HStack(spacing:12) {
                Button { store.move(item.id,to:index-1) } label: { Image(systemName:"chevron.left") }.disabled(index == 0).accessibilityLabel("向左移動\(item.title)")
                Button { store.remove(item.id) } label: { Image(systemName:"minus.circle") }.accessibilityLabel("移出\(item.title)").help("移出工作區，保持文件開啟")
                Button { store.move(item.id,to:index+1) } label: { Image(systemName:"chevron.right") }.disabled(index == store.order.ids.count-1).accessibilityLabel("向右移動\(item.title)")
            }.font(.caption).buttonStyle(.borderless)
        }.padding(10).frame(maxWidth:.infinity).frame(height:146)
            .laneGlass(selected:item.id == store.order.activeID)
            .disabled(store.isBusy)
    }
    private func emptyState(_ title:String,detail:String,symbol:String) -> some View {
        HStack(spacing:16) {
            Image(systemName:symbol).font(.system(size:28)).foregroundStyle(Theme.primary)
            VStack(alignment:.leading,spacing:6) { Text(title).font(.callout.weight(.medium)); Text(detail).font(.caption).foregroundStyle(Theme.muted) }
            Spacer()
        }.padding(20).frame(maxWidth:.infinity,minHeight:105)
            .background(Theme.surface.opacity(0.45),in:RoundedRectangle(cornerRadius:Theme.cardRadius))
    }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Image(systemName:"macwindow").resizable().scaledToFit().foregroundStyle(Theme.primary) } }.frame(width:size,height:size)
    }
}

struct RailView: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        LaneGlassGroup(spacing: 6) {
        HStack(spacing:14) {
            Image(systemName:"rectangle.3.group").foregroundStyle(Theme.primary)
            Button { store.step(-1) } label: { Image(systemName:"chevron.left") }.disabled(store.activeIndex == 0 || store.isBusy).accessibilityLabel("上一個視窗")
            ForEach(Array(store.ordered.enumerated()),id:\.element.id) { index,item in
                Button { store.select(item.id) } label: {
                    HStack(spacing:6) {
                        AppIcon(image:item.icon,size:18)
                        Text("\(index+1)").monospacedDigit()
                        if item.id == store.order.activeID { Text(item.appName).lineLimit(1) }
                    }.padding(.horizontal,10).padding(.vertical,8)
                        .fontWeight(item.id == store.order.activeID ? .semibold : .regular)
                        .background(item.id == store.order.activeID ? Theme.primary.opacity(0.08) : .clear,in:Capsule())
                }.buttonStyle(.plain).disabled(store.isBusy).help("\(item.title) · ⌃⌥\(index+1)").accessibilityLabel("切換至\(item.title)")
            }
            Button { store.step(1) } label: { Image(systemName:"chevron.right") }.disabled(store.activeIndex >= store.order.ids.count-1 || store.isBusy).accessibilityLabel("下一個視窗")
            Spacer(minLength:0)
            if store.isDemo { Text("示範").font(.caption).foregroundStyle(Theme.muted) }
            Button { store.toggleExpanded() } label: { Image(systemName:store.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.disabled(store.isBusy).help("暫時放大 · ⌃⌥↩").accessibilityLabel("切換暫時放大")
            Button("管理") { store.stop(); store.onShowManager?() }
            Button("設定") { store.onShowSettings?() }
            Button("退出") { store.stop(); store.onShowManager?() }
        }.buttonStyle(.borderless).padding(.horizontal,18).frame(maxWidth:.infinity,maxHeight:.infinity)
            .foregroundStyle(Theme.ink)
            .laneGlass(radius:Theme.railRadius)
        }
    }
}

struct EdgeView: View {
    @ObservedObject var store: WorkspaceStore
    let delta: Int
    var item: ManagedWindow? { let i = store.activeIndex + delta; return i >= 0 && i < store.ordered.count ? store.ordered[i] : nil }
    var body: some View {
        Group {
            if let item {
                Button { store.step(delta) } label: {
                    GeometryReader { geo in
                        ZStack {
                            // Unused preview space reveals the shared workspace backdrop.
                            Color.clear
                            if let image = item.snapshot {
                                // A preview is a crop of the neighboring window, not a
                                // magnified thumbnail. Keep its original point scale;
                                // only shrink an image that is taller than this screen.
                                let scale = min(1, geo.size.height / max(1, image.size.height))
                                Image(nsImage:image).resizable().interpolation(.high)
                                    .frame(width:image.size.width * scale,height:image.size.height * scale)
                                    .frame(width:geo.size.width,height:geo.size.height,
                                           alignment:delta < 0 ? .topTrailing : .topLeading)
                                    .clipped()
                            }
                            VStack(spacing:12) {
                                Spacer()
                                Image(systemName:delta < 0 ? "chevron.left" : "chevron.right").font(.title3.weight(.semibold)).frame(width:44,height:44).laneGlass(radius:22)
                                Spacer()
                                VStack(spacing:8) {
                                    AppIcon(image:item.icon,size:32)
                                    Text(item.appName).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                                    Text(item.snapshot == nil ? "名稱預覽" : "上次預覽").font(.system(size:10)).foregroundStyle(Theme.muted)
                                }.padding(10).frame(maxWidth:.infinity).laneGlass(radius:Theme.cardRadius)
                            }.frame(maxWidth:.infinity)
                        }
                    }
                }.buttonStyle(.plain).disabled(store.isBusy).help(item.title).accessibilityLabel("切換至\(item.appName)：\(item.title)")
            } else { Color.clear.overlay(Image(systemName:"minus").foregroundStyle(Theme.line)) }
        }.clipShape(RoundedRectangle(cornerRadius:Theme.cardRadius)).foregroundStyle(Theme.ink)
            .overlay(RoundedRectangle(cornerRadius:Theme.cardRadius).strokeBorder(Theme.glassRim,lineWidth:0.5).allowsHitTesting(false))
    }
}
