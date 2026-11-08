# Google SSE 串流中斷的本地擴充

## 修復目的

SwiftChat 透過 OpenCode Go 使用 Gemini 4 Argon 時，曾收到半截回答，隨後顯示
`Google stream ended without a finish reason`。HTTP 串流即使已送出文字，也可能
在模型回報結束原因前讀到 EOF。原本的 `.invalidResponse` 涵蓋多種解析錯誤，
而 SwiftChat 的重試依賴 URL 載入層回報的斷線碼，因此這次中斷直接結束了生成。
[URL 載入錯誤碼的本地擴充](TRANSPORT_ERROR_CODE_EXTENSION.md)

這項修復讓 SwiftChat 能辨識缺少結束原因的串流，重送發生中斷的那一次模型
請求，並沿用已完成的工具結果。接受版本 `86dc686c` 的 Google 轉接器也會把
缺少結束原因視為失敗。Swift 的 `.incompleteStream` 分類和 SSE 診斷屬於
使用者授權的 Class C 本地擴充。
[鎖定版本的上游行為](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/google-generative-ai.ts#L272-L292)
· [維護規則](AI_MAINTENANCE.md#class-c--policy-or-security-change)

## 套件與呼叫端的責任

- Google Generative AI 和 Vertex 共用轉接器。它讀完 HTTP 2xx 回應後，先解析
  EOF 時仍留在 SSE 解碼器的事件。若到這時仍未從第一個 candidate 讀到
  字串型別的 `finishReason`，便以 `.incompleteStream` 結束該次嘗試。
  `[DONE]` 會計入診斷，Google 的終止狀態由 `finishReason` 決定。
  SSE 或 JSON 語法錯誤、HTTP 錯誤和模型回報的安全停止各走自己的失敗分支。
  [Google 轉接器](../Sources/PiAIProviderRuntime/Wire/Google/GoogleGenerativeAIAdapter.swift)
  · [SSE 解碼器](../Sources/PiAIProviderRuntime/Wire/Common/ServerSentEvents.swift)
  · [公開錯誤型別](../Sources/PiAIProviderRuntime/ProviderRuntimeFailure.swift)
- SwiftChat 的 `AIChatStreamRetry` 負責退避及重試，最多重送五次。它以同一個
  `ProviderRequest` 呼叫原供應商及模型，請求內已有前序工具結果。它撤回中斷
  嘗試的暫存預覽，讓工作階段接收最後一次嘗試的事件與結果。重試耗盡時，
  最後一次嘗試仍以失敗結束。

## SSE 尾端診斷

`com.ronnie.pi-ai-swift` 的 `GoogleSSE` 類別在上述 EOF 分支記錄
`event=google.sse.incomplete`。日誌只含事件名及下列結構欄位。錯誤的
`causeDescription` 附上從 `end` 起的結構摘要。

| 欄位 | 含義 |
| --- | --- |
| `requestID` | 呼叫端提供的 UUID。無法解析為 UUID 時，日誌顯示 `unavailable`。 |
| `end`、`httpStatus` | 結束方式 `eof` 與 HTTP 狀態碼。 |
| `sseEvents`、`doneMarkerSeen` | 交給轉接器處理的 SSE 資料事件數，以及是否見過 `[DONE]`。 |
| `eofPendingLineBytes`、`eofFlushedEvents` | EOF 時尚未處理的行緩衝位元組數，以及清空解碼器時取出的事件數。 |
| `lastJSONCandidates` | 最後一個 JSON 事件中的候選數。沒有候選資料時為零。 |
| `finishReasonFieldSeen`、`usageMetadataSeen` | 任一已解碼 candidate 是否出現 `finishReason` 鍵，以及是否已解析用量資料。 |

`finishReasonFieldSeen=true` 搭配 `.incompleteStream` 表示已解碼的資料中曾出現
這個鍵，但選定 candidate 沒有提供字串型別的結束原因。`false` 表示已解碼的
候選資料都缺少該鍵。要判定故障發生在供應商、傳輸路徑或本地解碼，仍需對照
同一次請求在其他邊界觀察到的資訊。

## 驗證與後續維護

- Adapter 回歸涵蓋文字輸出後缺少結束原因、`[DONE]` 出現在 EOF 緩衝中、
  第二個 candidate 帶有結束原因、合法的尾端 `STOP` 及破損的 JSON 尾端。
  Google 和 Vertex 的差異測試核對缺少終止欄位的失敗與部分事件。
  [Adapter 回歸](../Tests/PiAIProviderRuntimeTests/GoogleGenerativeAIAdapterTests.swift)
  · [差異測試](../Tests/PiAIProviderRuntimeTests/SourceDerivedFailureDifferentialTests.swift)
- 2026-11-08 的本機驗證中，`swift test` 的 264 項測試通過，接受版本與明確
  指定該版本的 `check-upstream.sh` 均回傳 `YES`。SwiftChat 的 OpenCode Go
  回歸在 macOS 與 iOS 模擬器用合成 SSE 驗證相同請求重送、單一工具結果與
  完整回答。原始實網中斷的 SSE 尾端仍待觀察。

上游同步時，以候選版本的 Google 和 Vertex 終止契約檢視此擴充。若採用等價
的公開錯誤分類，先讓 SwiftChat 改用該分類，並重跑 EOF、正常終止、診斷欄位
與工具結果重用的回歸案例，再移除本地分類。
