# WindowLane 交接狀態

更新日期：2026-10-07。獨立副本已建立並初始化 Git；建立時已核對來源及 App 與原目錄一致。現已從獨立工程建置、以固定 Apple Development 憑證簽署，並完成固定位置安裝與權限持續性驗證。本文件使用相對路徑；較早的功能測試仍是在原 Language 專案鏡像內執行。

目前日常安裝版本為 **0.2.1、build 8**，已固定簽署、更新 `/Users/zhangfei/Applications/WindowLane.app`，完整退出／重開後兩項權限仍有效。建置與安裝二進位一致；核心 **77 / 77**、原生 **78 / 78**、背景 **34 / 34**、外部 fixture **75 / 75**、目前 Obsidian 視窗 **11 / 11** 通過，共 **275 項**。完整來源／二進位／報告雜湊及限制見 [尺寸與焦點修正報告](verification/size-fix-build8.json)。原有約 15%／65% 透明度保持；最後恢復 ChatGPT、Obsidian、Safari 選取，工作區未啟動，待復原記錄為 0。舊日常 build 6 備份在 `dist/local-backups/WindowLane-build6-before-size-fix.app`。

## GitHub 原始碼整理（2026-10-07）

已整理原始碼上傳所需的建置說明、忽略規則與 macOS CI。建置脚本改為可設定簽署身分；新 checkout 預設臨時簽署，本機原有開發憑證身分移至不納入 Git 的 `scripts/signing.local.sh`。Xcode 個人狀態、建置產物與私密配置不納入 Git。

本輪重新執行核心 **77 / 77** 通過及 release 編譯通過；[核心紀錄](verification/core-github-preparation-2026-10-07.log)、[編譯紀錄](verification/build-github-preparation-2026-10-07.log)。僅整理發布流程，沒有替換日常安裝版、重新執行 GUI／外部應用測試、封裝 ZIP 或公證。上方 275 項仍是 2026-10-04 的歷史驗證。

## build 8 尺寸拒絕與並排焦點修正（2026-10-04）

使用者回報疑似 Obsidian 不接受尺寸而「閃退」。未找到對應 WindowLane 崩潰報告；確認原碼會在並排尺寸拒絕後退出整個工作區。build 7 原生回歸亦重現並排窗被第三窗遮住及焦點回跳。原生 AppKit 重複啟用／面板隱藏可能恢復舊 key window，不能只在 AX 寫入或一次焦點讀回後發布成功。

現在以持續穩定且與 WindowServer 相符的寬度讀回學習單窗限制，有限次數調整兩窗分界，保留小數翻頁位置。放不下或拒絕布局時，恢復上次接受的完整框及作用中窗，保持工作區運行；只有退回也失敗才退出並執行原始復原。原始 recovery 值不被覆寫。已保存並排無法容納已知最小寬度時改以單頁啟動並提示。先處理工具面板，再確認真正焦點及兩窗前後排序；準備好的單頁直接切換仍不寫位置、尺寸或最小化。

目前 Obsidian 視窗實測接受 **421 點**及 **320 點**寬度；並排、跨應用焦點、單頁切換及原始框／最小化復原均通過。因此未把使用者先前的尺寸拒絕或真正程序崩潰宣稱為已重現。原生 clamping fixture 另驗證實際尺寸拒絕的適配、無法容納的退回、退回後切換，以及保存並排啟動替代與最終原值復原。

## 連續翻頁與命名排版（build 7 來源已納入 build 8）

命名保存排版、設定內的主視窗寬度與螢幕、保留小數比例的連續側滑及真實兩窗布局已隨 build 8 完成上列回歸。build 7 當時簽署提示、排序失敗及未完成紀錄仍留在 verification/，不能作為目前結果。實際文件／圖片 payload 拖放、其他日常應用與跨螢幕仍未全面驗證；沒有重新封裝發布 ZIP 或公證。

## 固定安裝與權限（已完成）

日常啟動位置為 `/Users/zhangfei/Applications/WindowLane.app`。建置腳本固定使用使用者已建立的 Apple Development 憑證；Bundle ID 維持 `com.feizhang.windowlane`。簽章驗證通過，安裝副本與 `dist/WindowLane.app` 的二進位一致。

遷移時已透過系統設定更新此 App 的舊權限項目，保留另外辨識出的 Xcode debug executable 項目。App 內確認輔助使用與螢幕錄製均已允許；完整退出／重開後仍保留。再將 build 3 更新為 build 4，確認簽署產物已變、指定簽署條件一致，兩項權限仍保留且無須再次授權。最後僅有固定位置的一個實例執行，待復原記錄為 0；本次 **10 / 10 檢查通過**。

這次更新測試只改建置號及簽署產物，沒有改應用行為；不涵蓋憑證換發、預覽像素、切換／復原回歸、Developer ID 發布或公證。每日使用開啟固定位置的 `.app`；Xcode 的 Swift Package Run 仍是另一份除錯執行檔。

同日後續依使用者要求清理舊授權：經系統設定「Show in Finder」核對路徑，移除 Xcode DerivedData 內的 WindowLane 除錯執行檔，以及原 Language 鏡像內 WindowLaneFixture 的視窗控制授權。輔助使用與螢幕錄製清單均只保留固定安裝版的一個 WindowLane 項目；App 內「重新檢查權限」仍顯示兩項已允許。這次只移除授權項目，沒有刪除程式檔案。上方遷移時保留除錯項目的描述屬清理前的歷史狀態。

## 透明度分組更新（build 5）

依使用者要求，主視窗與設定視窗共用「應用與設定視窗透明度」，工作區背景及其預覽使用另一個「工作區透明度」。兩者沿用 0–80% 範圍及 35% 預設；舊設定以原應用／工作區值初始化兩組，退休原本設定視窗專用值，保留壁紙和模糊設定。

release 建置、固定簽署及安裝完成；隔離的背景／偏好檢查 **25 / 25 通過**，包含舊版設定轉換與獨立保存。原生設定頁實測共用值 43%、工作區值 27%，完整退出／重開後仍保留；測試後兩者恢復到原先約 35%。主視窗及設定頁已檢查，兩項系統權限仍已允許。這次沒有重跑直接切換／外部復原回歸；相關待辦維持。證據見 [background-transparency-build5.json](verification/background-transparency-build5.json) 與 [transparency-build5.json](verification/transparency-build5.json)。

## 本輪翻頁更新（build 6）

啟動時仍將全部視窗排列到共同主框，保持開啟堆疊。切換前可取得目前視窗的新快照；外部擷取等待預算 100 ms，單次 AX 讀取不超過 20 ms 或剩餘預算，結束讀取後立即恢復原逾時設定。缺圖、逾時、擷取忙碌、尺寸不符或系統 Reduce Motion 時直接交接焦點。

焦點確認成功後更新目前項目，以非啟用面板呈現 280 ms 的左右翻頁滑動、輕微透視與邊緣陰影，露出真正可操作的目標視窗。動畫不改變任何真實視窗的大小、位置或最小化狀態；鍵盤留在目標視窗，指標事件由短暫面板吸收。呈現完成後再接受下一次切換，另行更新邊緣預覽。退出同步清理面板並釋放動畫等待，再完成獨立復原。

中性液態玻璃、壁紙、應用／設定共用透明度和工作區獨立透明度維持。原生介面檢查時，使用者現有值為約 15%／65%，本輪沒有調整這些值。退出示範並重開後，已恢復原先兩個日常視窗的選取清單，保持未啟動狀態。

## 本輪驗證與限制

| 項目 | build 6 證據 |
| --- | --- |
| 核心 | **32 / 32**，[core-page-turn-build6.log](verification/core-page-turn-build6.log) |
| 原生整合 | **42 / 42**，[native-page-turn-build6.json](verification/native-page-turn-build6.json)；正反向動畫、實際編輯焦點、動畫中取消、文件與幾何復原、Reduce Motion／缺圖／尺寸錯配替代 |
| 外部整合 | **65 / 65**，[external-page-turn-build6.json](verification/external-page-turn-build6.json)；7 次實際翻頁、AX 焦點、原尺寸快照、切換期間幾何／最小化寫入增量 0、放大還原、取消與最終復原 |
| 背景偏好 | **25 / 25**，[background-page-turn-build6.json](verification/background-page-turn-build6.json) |
| 安裝與介面 | [page-turn-build6.json](verification/page-turn-build6.json)；固定身分不變、二進位一致、兩項授權已允許、原生快捷鍵前後切換及退出、重開後保持日常版本 |
| 靜態設計審查 | strict 0 問題，[premium-audit-page-turn-build6.json](verification/premium-audit-page-turn-build6.json)；官方 DESIGN.md linter 離線缺少套件，未宣稱通過 |

原生完成呈現耗時中位約 373 ms（11 次），外部約 477 ms（7 次）；包含擷取、焦點、280 ms 動畫及診斷讀回。請勿把整段耗時當作純焦點耗時：原生／外部請求至焦點的中位分別約 55／144 ms。原生有一次約 502 ms 焦點確認，完整呈現約 801 ms，沒有宣稱固定延遲上限。

外部報告只涵蓋獨立 fixture 程式的三個文件，不能代表所有跨應用。原生 UI 工具已檢查切換完成畫面與編輯焦點，沒有以靜態截圖宣稱連續動畫的幀率或主觀流暢度。macOS 14–25、跨螢幕、休眠／崩潰等仍未全面驗證。

最初直接由 shell 啟動測試時，系統回報兩項權限不可用；沒有移動任何視窗。改用正常 App 啟動方式執行相同固定安裝版後，沿用既有權限完成外部驗證，無須重新授權。初始啟動情境報告保留於 [external-page-turn-build6-exec-context.json](verification/external-page-turn-build6-exec-context.json)。

## 後續範圍

1. 按使用者實際使用回饋微調翻頁觀感，擴充不同日常應用的相容性驗證。
2. 需要發布時，再封裝已驗證的 App 並核對來源、二進位、報告及 ZIP 雜湊；本輪本機更新不包含發布封裝或公證。

## 專案入口

独立工程目錄：`/Users/zhangfei/Documents/Codex/WindowLane`。在 Codex 新增本機專案並選擇此目錄，即可從專案內繼續工作；目前工具因安全限制無法操作 Codex 主介面，尚未代為登記。資料夾與專案的關係見 [OpenAI 官方文件](https://learn.chatgpt.com/docs/projects)。

這是可獨立開啟的 Swift Package；Xcode 可開啟 `Package.swift`。產品說明從 [README.md](README.md) 開始，未完成工作以上述「下一步」為準。
