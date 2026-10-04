# WindowLane 交接狀態

更新日期：2026-10-04。使用者要求形成獨立 project；獨立副本已建立並初始化 Git，來源及 App 已核對與原目錄一致。本文件使用相對路徑。下述測試在原 Language 專案鏡像內的 WindowLane 目錄執行；新路徑尚未完成啟動或權限驗證，獨立 Codex project 的註冊仍需使用者完成。

目前版本 **0.2.1、build 3** 已完成 release 編譯及 ad-hoc 簽章驗證，**尚未完成本輪發布封裝**。[direct-switch-progress.json](verification/direct-switch-progress.json) 記錄二進位 SHA-256 與待完成狀態；現存 0.2.0 ZIP／建置清單屬歷史版本，不能作為 0.2.1 交付證據。

## 本輪已實作

針對切換收起／縮放動畫造成卡頓，改為啟動時將全部管理視窗排列到共同主框並維持開啟堆疊。正常選取只交接原生焦點，不等待影像擷取、不重複縮放或最小化；放大／還原涵蓋全部視窗。退出仍等待取消中的操作結束並恢復原始框及最小化狀態，不確定的復原記錄繼續保留。

既有中性液態玻璃、預設 35% 毛玻璃、本機壁紙、應用／工作區與設定視窗獨立透明度、外觀／切換／權限設定均保留。產品範圍與來源分工見 [AGENTS.md](AGENTS.md)，詳細設計與操作契約見 [DESIGN.md](DESIGN.md)／[UX-CONTRACT.md](UX-CONTRACT.md)。

## 已驗證與限制

| 項目 | 本輪證據 |
| --- | --- |
| 核心 | **32 / 32 通過**，[core-direct-switch-tests.log](verification/core-direct-switch-tests.log)，2026-10-04 16:17:38 CEST |
| 背景與偏好 | **23 / 23 通過**，[background-smoke.json](verification/background-smoke.json)，2026-10-04T14:17:09Z |
| 原生整合 | 初次焦點檢查失敗，後續操作工具回報 Mac 已鎖定；[初始失敗報告](verification/native-smoke-direct-initial-failure.json) 保留。最新 build 的最終原生檢查待解鎖後重跑，不能判為通過或逕行歸因於程式回歸 |
| 外部／UI／耗時／封裝 | **待完成**；現有外部 44 項通過及 Safari 完整復原屬 0.2.0 歷史證據，見 [TESTING.md](verification/TESTING.md) 的歷史區段 |

## 下一步

1. 使用者解鎖 Mac 後，確認既有工作區已復原並依序執行原生、fixture host／外部整合測試；沿用使用者授權，核對實際權限狀態，不清除未解決的 recovery 記錄。
2. 核對同應用及跨應用的真正焦點；啟動後連續正常切換的 position／size／minimize 寫入增量必須為 0。放大／還原後再次切換亦須符合，並測試啟動、焦點交接與放大途中取消後的原始框／最小化復原。
3. 實際檢查直接切換觀感、清晰邊緣預覽及獨立設定；分別記錄同應用／跨應用焦點耗時、樣本數與範圍，不宣稱所有硬體延遲上限。新目錄另核對啟動與系統權限。
4. 將最終結果寫回驗證紀錄，再用 `bash scripts/package-app.sh` 封裝已測試的 0.2.1 App，核對來源、二進位、報告及 ZIP 雜湊；最後確認獨立 Codex project 已註冊。勿以舊報告完成本輪交付。

## 專案入口

独立工程目錄：`/Users/zhangfei/Documents/Codex/WindowLane`。在 Codex 新增本機專案並選擇此目錄，即可從專案內繼續工作；目前工具因安全限制無法操作 Codex 主介面，尚未代為登記。資料夾與專案的關係見 [OpenAI 官方文件](https://learn.chatgpt.com/docs/projects)。

這是可獨立開啟的 Swift Package；Xcode 可開啟 `Package.swift`。產品說明從 [README.md](README.md) 開始，未完成工作以上述「下一步」為準。
