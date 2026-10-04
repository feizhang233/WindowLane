# WindowLane 驗證紀錄

## 0.2.1 直接切換更新（最終驗證待完成）

使用者回報切換時收起／縮放動畫造成卡頓，0.2.1 預設改為直接提升原生視窗並交接焦點。啟動時保存每個視窗的原始框與最小化狀態，再一次排列全部視窗到共同 main frame，解除最小化並維持前後堆疊。正常選取只執行 focus，成功後才更新作用中 ID；不再反覆 place／park 或播放 180 ms 快照滑動。短暫輸入遮罩沒有動畫，在實際焦點交接前釋放。

預覽在切換完成後以 background task 更新，不等待擷取才切換；取消或新操作仍以 token 排除舊結果。暫時放大與恢復會一次調整所有受管理視窗，避免下一次直接切換回到舊尺寸。退出仍取消舊操作並等待其結束，再獨立恢復所有原始框與原最小化狀態，失敗保存記錄。中性玻璃、壁紙、兩種透明度及橫向切換偏好維持原設定。

**最新二進位的數量、耗時與封裝結果尚待完成，先前 0.2.0 的 129 項不能作為本輪通過依據。** 正常切換的延遲與啟動、放大／還原、復原布局的耗時分開記錄；測試中的焦點耗時不等同於所有硬體的畫面呈現延遲。

| 檢查 | 目前結果 | 最終需要的證據 |
| --- | --- | --- |
| 核心／原生／背景回歸 | **核心 32 / 32、背景 23 / 23 通過；原生待解鎖後重測** | [core-direct-switch-tests.log](core-direct-switch-tests.log)，2026-10-04 16:17:38 CEST；[background-smoke.json](background-smoke.json)，UTC 2026-10-04T14:17:09Z。包含兩透明度、壁紙與切換偏好保存 |
| 外部整合與堆疊 | **待最終結果** | 啟動後全部共同框且未最小化；同應用及跨應用選取的真正焦點身分正確，其他文件保持開啟 |
| 正常切換寫入次數 | **待最終結果** | 在 start 完成後取 backend baseline；連續切換的 size／position／minimize 寫入增量皆為 0，不以最後框相同推斷沒有中途寫入 |
| 放大／還原後切換 | **待最終結果** | 每次布局調整涵蓋所有視窗；再選取不同視窗仍不產生重複幾何／最小化寫入 |
| 焦點耗時 | **待測量** | 每次請求到真正焦點完成的時間、樣本數及範圍；同應用／跨應用分開說明，不宣稱普遍延遲上限 |
| 取消與退出復原 | **待最終結果** | 啟動、直接焦點交接及整組放大途中取消；沒有延遲選取／寫入，全部原始框、最小化狀態及復原記錄符合原值 |
| 原生 UI 與封裝 | **待完成** | 本輪直接切換觀感與設定 UI；完成後產生 `WindowLane-0.2.1-arm64.zip` 及最終來源／報告 SHA-256 |

本輪初次原生測試的焦點檢查未通過；随后操作工具回報 Mac 已鎖定，不能把鎖定中的結果歸因於切換回歸。初始報告保留為 [native-smoke-direct-initial-failure.json](native-smoke-direct-initial-failure.json)。最後修正增加可取消的實際原生 keyWindow 確認、啟用後最多一次焦點重送，以及無動畫的交接面板。最新二進位已編譯、簽章驗證通過；[direct-switch-progress.json](direct-switch-progress.json) 記錄目前雜湊，尚未封裝，等候使用者解鎖後完成原生、外部與 UI 驗證。

歷史 0.2.0 的報告、UI 與建置清單已保留為 `*-stability-v020.json`。下方歷史結果不涵蓋此次直接切換架構；最新 current smoke 報告及建置清單可能在本輪調試期間更新。

## 0.2 穩定性與設定視窗更新（歷史 0.2.0 結果）

本輪修正針對位置／焦點交接、退出未復原及異常結束問題：排列與焦點等待採可取消的非同步操作；退出先取消舊操作並等待其結束，再由獨立任務復原，復原期間禁止啟動新工作區。結束程式使用 terminateLater 等待復原；取消動畫也會取消其後續提交。輸入遮罩保留至幾何與最小化處理完成，再釋放並核對真正的系統焦點。快照同時最多一個底層擷取，過期、取消及逾時結果不再寫回。

設定改為獨立視窗，分為外觀、切換及權限；應用／工作區與設定視窗透明度各自保存。已允許的權限收納於設定。橫向輸入共用一個 gate，提供 30–180 閾值和工作區／僅切換條範圍；外部觸發核對具體聚焦視窗並避開 modal sheet，原應用仍會收到自己的捲動事件。

最後編譯版本的四組自動檢查合計 129 項均通過。原生介面確認獨立設定與權限收納；使用者確認實體滑鼠可以切換，小幅滑動不誤觸。此次 Safari 原始視窗亦已完整復原。這些結果不代表所有應用、硬體與長時間休眠／崩潰情境都已驗證。

| 檢查 | 目前結果 | 證據與待完成事項 |
| --- | --- | --- |
| 核心單元測試 | **32 / 32 通過** | [core-stability-tests.log](core-stability-tests.log)，2026-10-04 15:45:00 CEST；包含滾輪 gate 邊界與新增幾何輔助規則，來源與最終清單對應 |
| 原生整合 | **修正版 30 / 30 通過** | [native-smoke-stability-v020.json](native-smoke-stability-v020.json)，UTC 2026-10-04T13:45:57Z；新增啟動取消、動畫取消、反覆切換與退出保留文件 |
| 背景與偏好設定 | **修正版 23 / 23 通過** | [background-smoke-stability-v020.json](background-smoke-stability-v020.json)，UTC 2026-10-04T13:46:19Z；含獨立透明度、舊 v1 遷移、數值邊界及切換偏好保存 |
| 獨立測試應用外部整合 | **44 / 44 通過** | [external-smoke-stability-v020.json](external-smoke-stability-v020.json)，UTC 2026-10-04T13:48:48Z；三個外部文件、實際 AX 焦點、預覽尺寸、放大／還原、連續輸入、啟動取消及動畫後提交途中退出，最終原始幾何與復原記錄核對 |
| 設定原生 UI | **限定場景通過** | [ui-stability-stability-v020.json](ui-stability-stability-v020.json)；獨立設定視窗、外觀／切換／權限分類已確認。兩透明度調至應用 43%／設定 27%，重開仍保留，最後恢復 35%／35%。已允許兩權限時主介面不顯示授權卡片；自動操作工具的橫向捲動未觸發切換，因此未列為通過；實體滑鼠操作由使用者確認「可以切換，小幅滑動不誤觸」，範圍為本次三文件、閾值 80／工作區模式。原生退出後已核對恢復訊息及空復原記錄 |
| Safari 原始位置復原 | **本次保存框完整復原通過** | [ui-stability-stability-v020.json](ui-stability-stability-v020.json)；原先保存框 `(-9, 67, 2558, 1390)` 被限制成 `(-9, 67, 2558, 1373)`，在 y=67 放大時碰到螢幕底邊 1440。保守暫時位置處理後，backend 最終 AX＋WindowServer 驗證通過原始完整框；原生介面顯示復原完成，使用者原有 recovery.json 清空。未放寬尺寸檢查，也未概括所有 Safari 視窗／螢幕 |
| 0.2 封裝／建置清單 | **已完成** | [WindowLane-0.2.0-arm64.zip](../dist/WindowLane-0.2.0-arm64.zip)；[build-manifest-stability-v020.json](build-manifest-stability-v020.json) 保存最終二進位、ZIP、來源及三份整合報告 SHA-256 |

復原查找已分離於新增視窗的資格篩選：沿用已保存的程序／啟動身分與視窗識別資料，不使用標題重新綁定。暫時讀不到身分、視窗清單、位置或唯一對應時保留記錄；只在成功復原、確認原程序已結束／被替換，或使用者明確確認手動完成後清除。記錄損壞會阻止新工作區，並提供查看記錄及手動確認。自動原生／外部測試改用每次執行專用的臨時復原檔，避免消耗使用者未解決的 Safari 記錄。

strict 介面靜態審查 0 項問題，見 [premium-audit-stability-stability-v020.json](premium-audit-stability-stability-v020.json)。官方 DESIGN.md linter 套件未取得的既有限制仍保留，未宣稱通過。下方為各次歷史結果與限制，最新 0.2.1 狀態以最上方區段為準。

## 中性玻璃配色更新（歷史 0.1 結果）

依據 Apple 的[色彩規範](https://developer.apple.com/design/human-interface-guidelines/color)、[按鈕規範](https://developer.apple.com/design/human-interface-guidelines/buttons)及[材質規範](https://developer.apple.com/design/human-interface-guidelines/materials)，移除固定藍色與整個介面的共用染色。一般玻璃按鈕保持未染色，啟動／完成採適應明暗模式的中性強調；卡片以中性邊框表示選取，切換條以字重和 8% 中性色底表示目前位置。系統焦點框與控制項仍使用 Mac 的強調色。

原生 UI 已檢查淺色管理畫面及背景設定、程式自身的深色預覽，以及降低透明度的實色替代預覽；一般按鈕、選取卡片與主要動作沒有固定藍底，文字可辨識。內建示範和外部測試文件均已啟動及退出，管理畫面確認視窗恢復原位置與尺寸。詳見 [ui-neutral-glass.json](ui-neutral-glass.json)。深色及降低透明度旗標只影響本程式，沒有修改系統設定。工作區工具本次取得的是背景視窗截圖，未宣稱切換條和兩側預覽的完整合成效果目視通過。

最終編譯版本的回歸報告：

- 原生視窗整合：**25 / 25 通過**；UTC 2026-10-04T10:49:57Z。[native-neutral-2026-10-04.json](native-neutral-2026-10-04.json)。
- 獨立測試應用的外部視窗整合：**39 / 39 通過**；UTC 2026-10-04T10:46:05Z。[external-neutral-2026-10-04.json](external-neutral-2026-10-04.json)。
- 本機背景設定與匯入：**13 / 13 通過**；UTC 2026-10-04T10:50:10Z。[background-neutral-2026-10-04.json](background-neutral-2026-10-04.json)。

strict 介面靜態審查 0 項問題，見 [premium-audit-neutral-glass.json](premium-audit-neutral-glass.json)。本次沒有修改視窗控制、擷取、原尺寸裁切、背景設定或圖片匯入，核心單元測試沿用既有 13 項通過結果。官方 DESIGN.md linter 未取得套件的限制沿用下列紀錄；較舊 macOS、實際系統外觀偏好與任意壁紙對比仍未全面驗證。

## 半透明毛玻璃與自訂壁紙更新

管理介面、設定預覽與工作區背景共用同一個背景設定及繪製元件。預設為 35% 透明的 behind-window 毛玻璃；新增本機圖片選擇、透明度（0–80%）、壁紙模糊（0–60 pt）、恢復預設與移除副本。邊緣文件影像維持原尺寸裁切，未使用的高度透出整體背景。壁紙最長邊限制為 4096 像素，匯入保留原圖；設定與副本只在本機保存。

原生 UI 檢查確認選圖後壁紙出現在主介面與設定畫面，滑桿可調至 43%／18 pt；實際退出並重開後數值與圖片仍保留。毛玻璃／壁紙模式切換與取消更換圖片亦通過。最後已恢復 35% 毛玻璃並移除測試副本，測試原圖仍保留。詳見 [ui-background.json](ui-background.json)。

最終編譯版本的回歸報告：

- 本機背景設定與匯入：**13 / 13 通過**；UTC 2026-10-04T10:35:49Z。[background-2026-10-04.json](background-2026-10-04.json)。
- 原生視窗整合：**25 / 25 通過**；UTC 2026-10-04T10:36:18Z。[native-background-2026-10-04.json](native-background-2026-10-04.json)。
- 獨立測試應用的外部視窗整合：**39 / 39 通過**；UTC 2026-10-04T10:34:44Z。[external-background-2026-10-04.json](external-background-2026-10-04.json)。

背景測試使用隔離的偏好設定與臨時儲存目錄，涵蓋預設、有效圖匯入、原圖完整、尺寸上限、重新載入、來源移除、錯誤圖片、數值邊界、恢復預設、損壞副本回退及移除副本。外部測試首次因獨立測試程式未執行而停止，沒有修改其他視窗；保留於 [external-background-fixture-absent.json](external-background-fixture-absent.json)，啟動測試程式後最終 39 項通過。

strict 介面審查 0 項問題，見 [premium-audit-background.json](premium-audit-background.json)。完整工作區背景共用已檢查的繪製元件，但介面工具在工作區模式只能截到切換條，未以該截圖宣稱整個螢幕的合成效果目視通過。不同個人圖片的對比、舊版 macOS、實際系統降低透明度／提高對比仍未全面驗證。原先的 DESIGN.md 官方 linter 套件未快取且網路無法取得，該項限制沿用既有紀錄。

背景測試可明確啟動：

```sh
open -n dist/WindowLane.app --args --background-smoke-test \
  --report-path "$PWD/verification/background-smoke.json"
```

## 液態玻璃介面更新

介面使用 macOS 26+ 原生 `glassEffect`、`GlassEffectContainer` 及玻璃按鈕；管理視窗以 AppKit behind-window material 銜接透明標題列。`GlassUI.swift` 統一材質、按鈕及降低透明度／提高對比的替代分支；文字採系統語意色並跟隨明暗外觀。

已透過原生 UI 檢查深色玻璃管理畫面、搜尋篩選／無結果／清除，以及本機 `--ui-preview-reduce-transparency` 的實色替代外觀。這些預覽旗標只影響程式自身，沒有更改 macOS 設定。實際系統偏好切換與 macOS 14–25 材質替代仍未逐一實機驗證。

深色檢查發現捲動清單內的玻璃按鈕會繪出清單邊界，已改為原生 bordered 按鈕，並加上 ScrollView 裁切。文件預覽不套用玻璃模糊，仍使用前次驗證的原尺寸裁切。

最終淺色管理畫面已由原生 UI 截圖檢查，清單按鈕保持在視窗清單內，文字與選取狀態可辨識；先前的三個工作區視窗已重新加入管理清單。較窄視窗的拖曳調整未成功，因此未將最小尺寸目視列為通過。

strict 介面審查結果見 [premium-audit-liquid-glass.json](premium-audit-liquid-glass.json)。官方 DESIGN.md linter 本次以離線模式執行，因套件沒有快取而無法完成，見 [design-lint-liquid-glass.log](design-lint-liquid-glass.log)；未宣稱通過。原生玻璃由合成器呈現，`manager.png` 的離屏繪圖不能代替實際視窗外觀檢查。

日期：2026-10-03～2026-10-04（Europe/Belgrade）。液態玻璃交付版本的原生 25 項與外部 39 項回歸已通過並重新封裝。先前清晰度修正時，使用者確認 DELL 螢幕上、TextEdit／Document A、B 工作區右側 Document B 的文字「已清楚，可以使用」；玻璃更新沒有修改影像擷取或裁切。該目視結果不延伸至其他螢幕或內容。

## 歷史液態玻璃／清晰度版結果

| 層級 | 結果 | 實際範圍 |
| --- | --- | --- |
| 核心單元測試 | **13 / 13 通過，核心未變更** | 沿用先前結果：六視窗上限、識別與選取一致性、排序與移除、端點切換、儲存資料正規化、版面邊界與放大、負座標、座標往返及恢復資料序列化 |
| 原生整合測試 | **修正版 25 / 25 通過** | 三個本程式建立的 NSWindow／NSTextView、工作區啟動、排序後切換、輸入焦點、未完成文字與選取保留、放大與還原、退出後原始幾何復原、移除不關閉文件 |
| 外部應用整合 | **修正版 39 / 39 通過** | 獨立測試應用的三個視窗：身分、啟動、四次選取、實際焦點、幾何與最小化、放大及還原、退出復原及記錄完成；另驗證主視窗擷取的原生像素與邏輯點尺寸 |
| ScreenCaptureKit 影像返回 | **3 / 3 有有效尺寸** | 上列外部整合中的三個檢查：已授權並取得三張 720 × 588 影像。只檢查 CGImage 存在、寬與高大於零；未驗證像素內容、畫面對應、裁切或色彩 |
| 主視窗快照尺寸 | **2 / 2 通過** | 上列外部整合新增的兩個檢查：2110 × 1306 像素，對應 2110 × 1306 點與 1× 螢幕比例；NSImage 邏輯點尺寸亦符合。尚未驗證 Retina 螢幕的實際結果 |
| 邊緣預覽目視 | **修正版右側文字確認可用** | 使用者回覆「已清楚，可以使用」。僅涵蓋此次 DELL 螢幕與 TextEdit／Document A、B 工作區右側 Document B 的文字清晰度，未概括其他螢幕、內容或色彩準確性 |
| TextEdit 跨應用操作 | **人工原生 UI 檢查通過** | 新建草稿與獨立測試程式的 Document A 往返；以 AX 確認三行草稿內容及「保留狀態」文字選取保持。不計入 39 項自動檢查 |
| 管理介面圖像 | 已產生 | `manager.png`：從本程式原生內容視圖繪出的 1010 × 760 PNG；此圖不能證明其他應用的螢幕擷取已通過 |

液態玻璃版原生整合的逐項證據在 [native-liquid-glass-2026-10-04.json](native-liquid-glass-2026-10-04.json)，完成於 2026-10-04 11:45:02 CEST。三個原始視窗框與退出後視窗框完全相同，文字草稿與文字選取也保持一致。

液態玻璃版外部整合的證據在 [external-liquid-glass-2026-10-04.json](external-liquid-glass-2026-10-04.json)，完成於 2026-10-04 11:44:24 CEST，`status: passed`，39／39 通過。清晰度修正前的 [37 項外部報告](external-2026-10-04-before-clarity-fix.json) 與 [25 項原生報告](native-2026-10-04-before-clarity-fix.json) 亦已保留。下列較早的失敗紀錄另行保留：

- [幾何等待修正前](external-2026-10-04-before-settlement-fix.json)：10:43 CEST，10／13、failed。
- [首次預覽擷取測試](external-2026-10-04-preview-first-run.json)：10:50 CEST，14／15、failed。
- [分階段動畫測試](external-2026-10-04-staged-animation-failure.json)：10:53 CEST，12／16、failed。
- [放大處理修正前](external-2026-10-04-before-expand-fix.json)：11:02 CEST，35／37、failed。

請依 JSON 的 `completedAt`、`status`、`passed` 與 `checks` 判斷每一次執行；歷史失敗不被最終成功覆寫。JSON 的 `screenCaptureTest: pixel-output-verified` 只對應影像存在與有效尺寸，不代表像素內容正確性。

清晰度修正版新增且已通過 `main_window_capture_native_resolution` 與 `main_window_capture_logical_size`，分別檢查主視窗快照的像素尺寸及邏輯點尺寸。這兩項只驗證尺寸與中繼資料；右側文字清晰度另由使用者在上述限定場景確認，不以尺寸檢查代替視覺結果。修正版擷取使用 `filter.contentRect × filter.pointPixelScale`，邊緣預覽按原邏輯點尺寸顯示、只縮不放大，小圖高度不足時保留背景。

歷史 0.1 交付封裝的路徑相對於 `WindowLane` 專案根目錄：[dist/WindowLane-0.1.0-arm64.zip](../dist/WindowLane-0.1.0-arm64.zip)。中性玻璃版的封裝、來源與報告 SHA-256 保留於 [manifest-neutral-2026-10-04.json](manifest-neutral-2026-10-04.json)。目前 `dist/WindowLane.app` 及 current smoke 報告可能隨調試更新，最新 0.2 封裝結果以上方區段及最終建置清單為準。

## 測試方式

從 `WindowLane` 專案目錄執行：

```sh
swift test
./scripts/build-app.sh
open -n dist/WindowLane.app --args --smoke-test \
  --report-path "$PWD/verification/native-smoke.json" \
  --screenshot-path "$PWD/verification/manager.png"
```

原生測試會建立、使用並關閉它自己的三個測試文件，不會管理其他應用視窗。0.2 的原生與外部測試各自使用新的臨時復原檔，啟動時不讀取或覆寫使用者的待復原記錄；測試需要沒有其他測試同時操作這些文件。

外部 AX 測試另需啟動 bundle ID 為 `com.feizhang.windowlane.fixture` 的獨立測試程式，並以 `--fixture-host` 開啟其三份文件。該測試僅選取此 bundle 的指定三個視窗，刻意排除使用者平日的應用。授權必須由系統設定提供；測試本身不會按下授權提示或替使用者修改系統權限。

```sh
open -n verification/WindowLaneFixture.app --args --fixture-host
open -n dist/WindowLane.app --args --external-smoke-test \
  --report-path "$PWD/verification/external-smoke.json"
```

目前測試計畫涵蓋實際 AX 視窗身分、系統輸入焦點、全部視窗共同尺寸與堆疊、直接切換不重複寫入幾何／最小化、整組放大及退出復原；工作區啟動失敗時，切換與放大檢查不會執行。獨立測試程式通過也不能代替 PDF 閱讀器、瀏覽器、Excel 等應用的相容性驗證。

## 介面操作檢查

已在原生介面點選加入三個外部視窗、啟動、點選第二個位置並確認切換條選取狀態。示範模式下透過原生 UI 輸入 Control+Option+Right、Control+Option+3、Control+Option+Escape，分別觀察到 Document B、Document C 和已退出的管理畫面。這可證明應用內鍵盤路徑，不等於實體鍵盤的全域 Carbon 事件或觸控板手勢已驗證。

已透過原生 UI 在 TextEdit 建立三行測試草稿、選取「保留狀態」，再與獨立測試程式的 Document A 往返切換。回到 TextEdit 後，以 AX 確認三行文字及選取內容保持。這項檢查涵蓋兩個不同應用的焦點交接與該份未儲存草稿，尚未擴展至其他日常應用。

重新開啟主程式後，管理畫面曾顯示一筆待復原記錄。按「重試復原」後已確認成功，復原記錄清空。此項驗證涵蓋該次重開與重試，不等同於所有崩潰、斷電或失敗情境均已驗證。

本次介面工具只能擷取切換條視窗，無法由其截圖確認兩側預覽。使用者先確認舊版可見但不清晰；修正後，使用者目視此次 DELL 螢幕上的 TextEdit／Document A、B 工作區，確認右側 Document B 的文字「已清楚，可以使用」。這是使用者直接提供的目視結果，並非工具截圖推斷。

## 尚需補充的實機驗證

- 真正按下全域快捷鍵，以及實際觸控板橫向手勢；目前整合測試直接呼叫操作方法。
- Retina 與其他螢幕、其他內容的清晰度、畫面對應、裁切與色彩正確性；目前確認的是 1× 螢幕上的原生像素／邏輯尺寸，以及此次 DELL 場景右側 Document B 文字可用。
- 實際擷取阻塞時取消、切換後立即輸入的按鍵隔離，以及強制結束時的完整處理；0.2.0 已有啟動／動畫取消及外部幾何取消檢查，0.2.1 的直接交接與整組放大取消依上方本輪結果另行核對。
- 外接螢幕拔除、同一螢幕更改解析度／縮放、顯示器排列變更及 Dock 可用區域變更。
- 外部應用最初已最小化、應用正在忙碌、視窗關閉、使用者手動最小化、權限被撤銷和復原記錄寫入失敗。
- 程式崩潰、斷電等情境下的復原，以及無法復原時的完整手動處理流程；一般重新開啟後的一筆記錄重試已驗證。
- Reduce Motion、不同螢幕尺寸，以及 TextEdit 以外日常應用的焦點與未送出草稿保留。

## 實作邊界

中央是原應用的真實可操作視窗，兩側是最後一次成功擷取的靜態快照。此工具透過公開的 Accessibility、AppKit 與 ScreenCaptureKit API 管理外部視窗，沒有把任意其他應用的視窗嵌入自身。0.2.1 的全部受管理視窗保持開啟、解除最小化並疊於共同框，原生示範與外部應用都使用直接 focus；退出時仍各自恢復原始狀態。0.2.0 的外部視窗最小化與示範 `orderOut` 只描述歷史版本，不能混用來驗證新路徑。

本地 `.app` 已採臨時簽署。沒有宣稱 Developer ID 公證、App Store 發布或所有 Mac 應用相容。跨 Space／原生全螢幕、受保護的影像內容、應用自行限制的視窗尺寸及文件重新開啟不在已驗證範圍。

## 調試修正與工具限制

- 啟動、放大／還原與退出的視窗幾何依序處理：先將寬、高縮至目前與目標尺寸各自的較小值，移動至目標位置，再放大至目標尺寸並校正位置。每個變更階段等待實際狀態穩定後才繼續；正常直接切換不經這條幾何路徑。原始框部分超出螢幕時使用保守暫時位置，歷史 Safari 完整復原結果見 0.2.0 區段。
- 幾何穩定檢查每階段最多 1.2 秒，至少經過 0.30 秒，且連續符合目標至少 0.20 秒；容許誤差為 1 pt。讀回 AX 幾何，若已識別的 CGWindowID 仍屬於同一程序，亦核對 WindowServer 幾何。最小化狀態另等待最多 0.8 秒。
- AX 寫入等待上限為 1.2 秒；遇到 cannotComplete 時讀回確認並最多重試一次。清晰度修正版外部整合已再次通過啟動、切換、放大及復原檢查。
- 0.2.1 切換建立短暫無動畫輸入遮罩，在真正焦點交接前釋放；選用快照於切換完成後另行更新。整組放大與恢復在處理全部幾何後才返回作用中視窗。切換瞬間立即輸入的隔離仍待實機驗證。
- 跨應用焦點切換不只依賴 activation 回傳值；使用可用的 AX Frontmost、Main、Raise 與 FocusedWindow 操作，並最多等待 0.8 秒，確認系統目前焦點的程序與視窗身分確實符合目標。TextEdit 與獨立測試視窗的往返已驗證。
- 權限中斷、讀取失敗、活著的程序產生無效 AX 參照時，保留復原記錄。真正關閉的視窗若其應用仍在執行，可能需手動移除。
- 外接螢幕變更會比較目前的可用區與完整框，退出工作區並嘗試復原；實體拔插與長時間休眠仍未完整驗證。
- strict 介面靜態審查 0 項問題，Swift 編譯與本機簽章檢查通過。官方 DESIGN.md linter 因 registry.npmjs.org DNS 解析失敗而未執行成功；未宣稱該檢查通過。
- 螢幕錄製最初因未明確授權而遭自動審批拒絕；使用者在 2026-10-04 明確允許後，測試已讀取到授權，並取得三張具有效尺寸的影像。該結果與整體工作區幾何是否通過分開記錄。
