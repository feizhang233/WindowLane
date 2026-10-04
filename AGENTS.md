# WindowLane 專案工作指引

本檔提供專案背景，不能覆蓋較高優先級指示或使用者本輪要求；同時遵守適用的父目錄 `AGENTS.md`。原 Language 專案的 `sources/` 是同步的唯讀參考資料，勿修改。先讀 [CURRENT_STATE.md](CURRENT_STATE.md)、[README.md](README.md)、[DESIGN.md](DESIGN.md)、[UX-CONTRACT.md](UX-CONTRACT.md) 與 [驗證紀錄](verification/TESTING.md)，再依實際來源及最新報告判斷現況。

## 產品與已接受的行為

原生 AppKit／SwiftUI macOS 工具，以一個螢幕管理最多六個具體視窗；中央保留真正可操作的應用視窗，兩側是可選的靜態影像預覽。支援排序、點擊／快捷鍵／橫向滾輪切換、暫時放大和退出復原。同應用的不同視窗各有身分。雙視窗協作、多工作區、重新開啟文件及跨 Space／全螢幕仍屬後續範圍。

- **直接切換是預設**：啟動一次將全部視窗解除最小化並排列到共同主框，維持前後堆疊；正常切換只提升視窗並確認真正焦點，不反覆縮放、移動或最小化。焦點成功後才更新目前項目，影像更新不阻塞切換。放大／還原一次調整全部視窗。
- **復原不能丟失原值**：啟動排列前最後讀取並保存原框與最小化狀態，後續切換不覆寫；退出取消並等待舊操作，再由獨立任務復原。終止使用 `terminateLater` 等待結果。仍開啟但身分或幾何不確定的視窗保留 recovery 記錄，不以標題猜測或直接清空。
- **保留中性液態玻璃方向**：macOS 26+ 原生玻璃、14–25 材質替代，避免固定藍底。毛玻璃預設透明度 35%；應用／工作區與獨立設定視窗的透明度各自保存。使用者可選本機壁紙；降低透明度／提高對比時提供實色替代。外觀、切換、權限集中於獨立設定視窗。
- **預覽與輸入有明確邊界**：預覽依原邏輯點尺寸裁切，只縮不放大，正常擷取只留記憶體。橫向切換核對具體聚焦視窗並避開 modal sheet；外部監聽不吞掉原應用捲動事件。使用公開 AX、AppKit、ScreenCaptureKit API，不宣稱跨程序嵌入或即時預覽。

## 來源責任

| 檔案／目錄 | 責任 |
| --- | --- |
| `Sources/WindowLaneCore/`、`Tests/` | 排序、布局、座標、滾輪 gate、復原幾何及核心測試 |
| `Sources/WindowLane/WorkspaceStore.swift` | 工作區狀態、可取消操作、復原記錄與退出 |
| `Sources/WindowLane/WindowBackend.swift` | AX 身分、布局、焦點、復原候選、診斷與 PreviewCapture |
| `Sources/WindowLane/App.swift` | 原生視窗／面板、設定視窗、輸入遮罩與終止流程 |
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

`--disable-sandbox` 是本次主機使用的 SwiftPM 選項，仍遵守執行環境的權限規則。完整原生／背景／外部測試命令在 [TESTING.md](verification/TESTING.md)；GUI 測試依序執行，Mac 必須解鎖，外部測試先開 fixture host。測試使用獨立臨時 recovery 檔，不消耗使用者未完成的復原記錄。替換執行中的 App 前先退出工作區並完成復原。

以目前來源、App 版本、報告時間及雜湊核對驗證，不能把歷史通過當成本輪結果。`bash scripts/package-app.sh` 封裝已建置及測試的 App，不重新編譯；發布前確認清單對應同一二進位。依變更選擇有意義的測試，不為簡單可逆的外觀修改增加鏡像測試。既有使用者授權持續有效，同範圍的權限刷新沿用明確授權；系統實際要求的 Touch ID 或密碼由使用者操作。
