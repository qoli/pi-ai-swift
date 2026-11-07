# OpenAI Responses 的 keepalive 修復筆記

## 觸發條件

SwiftChat 讀取 Responses 串流時，服務端可能在回覆事件之間送出
`keepalive` 心跳。舊版 Swift 解析器會將它判為未知事件，拋出
`unsupported OpenAI Responses event: keepalive`，後續回覆也就讀不到。
只有串流實際送到這個事件的請求才會觸發。

## 上游行為與修正

這是針對既有上游版本 `86dc686cf2fd795b2b24af3d614bb0e1307bcd76`
的 Class B 修復。上游 `processResponsesStream` 先把原始事件交給觀察回呼，
再處理已知的回覆事件。心跳不匹配其中任何分支，迴圈會繼續讀取。
串流仍需要收到正常的終止事件。[鎖定版上游原始碼](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/openai-responses-shared.ts#L671-L816)

Swift 的 [Responses 解析器](../Sources/PiAIProviderRuntime/Wire/OpenAIResponses/OpenAIResponsesAdapter.swift)
現在把 `keepalive` 歸入不產生 `ProviderEvent` 的已知事件。原始觀察回呼仍會
收到心跳。解析器繼續處理後續的文字、工具呼叫和完成事件。上游 pin 保持在同一個
commit。

## 回歸案例

[測試輸入](../Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json)
使用合成 SSE 資料。[預期輸出](../Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json)
由 `Scripts/openai-response-event-oracle.mjs` 執行鎖定的 TypeScript 產生。

- `keepalive-between-text-deltas` 把心跳插在兩段文字之間，逐一核對文字區塊
  的事件順序、合併結果和完成狀態。
- `responsesWireObserverCases.openai-responses` 核對原始觀察回呼能依序收到
  開始、心跳和完成事件。
- `responsesFailureEvents.earlyEof` 在心跳後直接結束連線，應回報缺少終止事件。

修復前，三項 Swift 回歸檢查都因為 `keepalive` 中斷而失敗。

## 本機驗證

- macOS 的 `swift test` 通過。需要 `SCHEMA6_CATALOG_PATH` 的目錄測試
  另用同一個 upstream revision 的目錄補跑，合計 259 項通過。
- iOS 27.0 模擬器的文字區塊、原始事件回呼與供應商錯誤測試共三項通過。
  `PiAIProviderRuntime` 也通過 arm64 和 x86_64 的模擬器編譯。
- 隔離的 AIReasoningCore 測試載入本機套件，使用同一份心跳測資驗證
  `respond` 和 `streamResponse` 都回傳完整文字。四項測試通過，也包含
  原有的無效回覆識別驗證。
- `Scripts/check-upstream.sh` 和帶有原 pin 的 `--candidate` 檢查都回傳
  `YES`。Swift 格式與差異檢查通過。

這些結果涵蓋本機套件與合成串流。SwiftChat 發行版需納入修復後的套件才能套用。
