# WindowLane 專案工作指引

本檔提供專案背景，不能覆蓋較高優先級指示或使用者本輪要求；同時遵守適用的父目錄 `AGENTS.md`。原 Language 專案的 `sources/` 是同步的唯讀參考資料，勿修改。先讀 [CURRENT_STATE.md](CURRENT_STATE.md)、[README.md](README.md)、[DESIGN.md](DESIGN.md)、[UX-CONTRACT.md](UX-CONTRACT.md) 與 [驗證紀錄](verification/TESTING.md)，再依實際來源及最新報告判斷現況。

## 產品與已接受的行為

原生 AppKit／SwiftUI macOS 工具，以一個螢幕管理最多六個具體視窗；單頁保留中央原生操作窗，部分翻頁保留兩個真實視窗並排，兩側可選靜態預覽。支援命名保存排版、排序、點擊／快捷鍵／連續或逐頁橫向滾輪、邊緣拖曳導覽、暫時放大和退出復原。同應用的不同視窗各有身分；一次運行一個工作區。自動重新開啟文件、同時運行多個工作區及跨 Space／全螢幕仍屬後續範圍。

- **逐頁直接交接，平滑呈現**：單頁啟動一次將全部視窗解除最小化並排列到共同主框，維持前後堆疊；準備好的單頁正常切換不反覆縮放、移動或最小化。切換前可擷取目前視窗的新快照，外部 ScreenCaptureKit 等候預算為 100 ms；缺圖、逾時、擷取忙碌、尺寸不符或 Reduce Motion 時直接交接焦點。真正焦點成功後才更新目前項目，再以記憶體快照播放 280 ms 的定向滑動與輕微翻頁傾斜；呈現結束前保持忙碌，遮罩不取得鍵盤焦點。邊緣預覽另行更新。進出並排及放大／還原的幾何成本不可混入單頁直接切換保證。
- **連續翻頁保留比例**：側滑直接累積小數頁位置，手勢結束或普通滑鼠約 160 ms 空閒後保留比例，不吸附至最近整頁。只將 0.002 內的整頁差值正規化；兩窗需遵守最小寬度。滾動中顯示記憶體快照／名稱卡片，原生幾何維持上次接受值；釋放後一次套用兩個相鄰原生窗並提升到其他受管理視窗前方，移除覆蓋影像，之後才能直接編輯／拖放。預覽中點擊、開始拖曳或前景應用變更取消未提交手勢；取消回到已接受位置。減少動態效果略過移動預覽，仍保留所選布局。
- **命名排版只選擇已開啟視窗**：本機原子 JSON 最多 24 個排版、每個六窗，保存名稱、固定視窗描述、順序、作用中項目、螢幕、單頁寬度及小數頁位置。優先同程序／WindowServer ID／啟動時間；重啟後僅用唯一的完全相同 Bundle ID 與非空標題。不猜相似標題、不部分套用，不重開應用或文件；缺少或不明確時保留目前工作區。命名匹配不能替代原始視窗復原的較嚴格身分規則。刪除可復原；讀取錯誤或新格式保留原檔，寫入失敗不發布新狀態。
- **兩窗拖放沿用原應用**：並排兩窗是真正可操作的原生視窗，來源／目標支援的文件、圖片等可由原生拖曳傳遞。單頁拖曳在可用邊緣停留約 450 ms 展開相鄰窗，再移入原生目標放下；同一停留只導覽一次。邊緣不接收資料、不讀取 payload、不解析 file promise、不另建拖曳工作。拖曳按住滑鼠時暫停滾輪翻頁；離開、拖曳結束及退出重置狀態。尺寸與焦點檢查不能宣稱所有應用均接受拖放，實際文件／圖片傳遞需分別驗證。
- **復原不能丟失原值**：啟動排列前最後讀取並保存原框與最小化狀態，後續切換／並排不覆寫；退出取消舊操作、連續手勢及拖曳導覽，同步移除所有翻頁遮罩與快照，再等待舊操作結束，由獨立任務復原。終止使用 `terminateLater` 等待結果。仍開啟但身分或幾何不確定的視窗保留 recovery 記錄，不以標題猜測或直接清空。
- **保留中性液態玻璃方向**：macOS 26+ 原生玻璃、14–25 材質替代，避免固定藍底。毛玻璃預設透明度 35%；應用主視窗與設定視窗共用透明度，工作區透明度獨立保存。使用者可選本機壁紙；降低透明度／提高對比時提供實色替代。獨立設定含外觀／工作區／切換／權限；主視窗寬度與螢幕移至工作區設定並本機保存，運行時停用，主畫面保留命名排版入口。
- **預覽與輸入有明確邊界**：預覽依原邏輯點尺寸裁切，只縮不放大，正常擷取只留記憶體。橫向切換核對具體聚焦視窗並避開 modal sheet；外部監聽不吞掉原應用捲動事件。使用公開 AX、AppKit、ScreenCaptureKit API，不宣稱跨程序嵌入或即時預覽。

## 來源責任

| 檔案／目錄 | 責任 |
| --- | --- |
| `Sources/WindowLaneCore/`、`Tests/` | 排序、布局、座標、滾輪 gate、復原幾何及核心測試 |
| `WorkspacePreset.swift`、`WorkspacePresets.swift`、`WorkspacePresetControls.swift` | Core 的排版描述／保守匹配／原子儲存，以及 App 的可觀察介接與共用命名 CRUD；不重開文件 |
| `BookPageLayout.swift`、`ContinuousScrollPaging.swift` | Core 的小數頁與雙窗幾何、側滑累積、取消與釋放後保留比例 |
| `Sources/WindowLane/WorkspaceStore.swift` | 工作區狀態、可取消操作、復原記錄與退出 |
| `Sources/WindowLane/WindowBackend.swift` | AX 身分、布局、焦點、復原候選、診斷與 PreviewCapture |
| `Sources/WindowLane/App.swift` | 原生視窗／面板、設定視窗、輸入遮罩與終止流程 |
| `Sources/WindowLane/PageTurnTransition.swift` | 記憶體快照翻頁呈現、方向、Reduce Motion 替代與可取消遮罩；不移動真實視窗或取得焦點 |
| `Sources/WindowLane/ContinuousPagePresentation.swift` | 連續輸入期間的記憶體快照、逐比例更新及移除；停止後由真實兩窗接手 |
| `Sources/WindowLane/DragTransferRouter.swift` | 原生 drag 的邊緣停留導覽、一次觸發與取消；不接收或複製 payload |
| `Views.swift`、`GlassUI.swift`、`BackgroundSettings*.swift` | 上列應用目錄內的管理／切換 UI、材質、獨立透明度與壁紙 |
| `InteractionSettings.swift`、`HorizontalScrollRouter.swift`、`GlobalShortcuts.swift` | 上列應用目錄內的切換設定及事件路由 |
| `SmokeCheck.swift`、`ExternalCheck.swift`、`BackgroundCheck.swift`、`verification/` | 原生／外部／背景驗證與逐次證據 |
| `Resources/Info.plist`、`scripts/` | 版本、原生 App 建置、簽章檢查與 ZIP 封裝 |

## 建置與驗證

在專案根目錄執行：

```sh
swift test --disable-sandbox
bash scripts/build-app.sh --disable-sandbox
open dist/WindowLane.app
```

`--disable-sandbox` 是本次主機使用的 SwiftPM 選項，仍遵守執行環境的權限規則。完整原生／背景／外部測試命令在 [TESTING.md](verification/TESTING.md)；GUI 測試依序執行，Mac 必須解鎖，外部測試先開 fixture host。測試使用獨立臨時 recovery／排版檔及範圍偏好，不消耗使用者未完成的復原記錄或已保存排版。拖曳驗證只使用隔離的來源、目標及測試資料，不將窗口可見等同 payload 已被接收。替換執行中的 App 前先退出工作區並完成復原。

以目前來源、App 版本、報告時間及雜湊核對驗證，不能把歷史通過當成本輪結果。`bash scripts/package-app.sh` 封裝已建置及測試的 App，不重新編譯；發布前確認清單對應同一二進位。依變更選擇有意義的測試，不為簡單可逆的外觀修改增加鏡像測試。既有使用者授權持續有效，同範圍的權限刷新沿用明確授權；系統實際要求的 Touch ID 或密碼由使用者操作。
