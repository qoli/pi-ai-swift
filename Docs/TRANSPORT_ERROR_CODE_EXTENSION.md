# URL 載入錯誤碼的本地擴充

pi-ai-swift 提交 `64c0a468e7032163afc3fc6803374a16fb887893` 於 2026-11-07
為 SwiftChat 的斷線復原（5ML-188）增加了公開欄位
`ProviderRuntimeFailure.underlyingURLErrorCode`。這是為消費端增加的本地介面，
涉及 Class C 的公開介面決策門檻。原修復隨 SwiftChat 的重試功能一起交付，
當時沒有單獨提出這項介面決策。[維護規則](AI_MAINTENANCE.md#mechanical-semantic-translation-only)

## 上游契約與擴充原因

此變更以 `86dc686cf2fd795b2b24af3d614bb0e1307bcd76`（`@earendil-works/pi-ai`
1.4.0）為接受版本，pin 保持在該提交。以 Google 為例，鎖定版上游將捕獲的
錯誤格式化為 `errorMessage`，再透過 `AssistantMessageEvent` 的 `error` 分支
交付。新增欄位承載 Apple URL 載入層的資訊，屬於 Swift 下游的額外輸出。
[上游公開事件](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/types.ts#L821-L837)
[上游 Google 錯誤處理](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/google-generative-ai.ts#L286-L293)

SwiftChat 從 `ProviderRuntime.stream` 收到原始 `URLError` 時，可以直接辨認
`networkConnectionLost`（`-1005`）。Google 等 Swift 轉接器會把原始錯誤包成
`.transportFailed`，底層原因原先只剩 `causeDescription` 字串。此時呼叫端的
型別資訊不足以可靠區分斷線和其他傳輸失敗。擴充將數字碼保留在原始錯誤被
包裝的位置，讓 SwiftChat 在同一層判斷原始及已包裝的斷線。

## 責任範圍

- pi-ai-swift 只保留錯誤資訊。Google、Mistral、Bedrock 和 OpenRouter Images
  在包裝底層 `URLError` 時留下數字碼。Bedrock、Anthropic 和 OpenAI Responses
  在補充既有失敗資訊時保留該欄位。`underlyingURLErrorCode` 是可選的
  `Int`，舊資料缺少這個鍵時可解碼為 `nil`。有值時，編碼會多出這個鍵。
  [Swift 錯誤型別](../Sources/PiAIProviderRuntime/ProviderRuntimeFailure.swift)
- SwiftChat 的 `AIChatStreamRetry` 決定如何處理 `networkConnectionLost` 和
  `notConnectedToInternet`。同一模型請求最多重試五次，退避、撤回本次的
  暫存串流片段，以及沿用先前已完成的工具結果，都由 SwiftChat 負責。
  使用的套件由 SwiftChat 專案透過 `../pi-ai-swift` 引用。

## 驗證紀錄

SwiftChat `3ac368f450ffeb1016300b3f9c7946da8112b605` 搭配 External/Tests
`44494f2765c2a8aae4e281246452bdfd9ea45683`，以合成串流驗證消費端行為。

- `testCustomResponsesStreamRetriesAfterCompletedTool` 在已完成檔案工具的
  後續請求注入 `-1005`。修復前整輪失敗，修復後接續原請求，檔案工具只執行一次。
- `testGoogleStreamRetriesWrappedDisconnectAndPreviewsDeltas` 透過實際 Google
  Swift 轉接器包裝注入的 `-1005`，確認 SwiftChat 重試後在串流結束前
  顯示推理和文字，且最終只保留該請求成功嘗試的片段。

兩案均通過 macOS 測試，並在 iPadOS 26.5 模擬器上重跑通過。SwiftChat Dev
另用已配置的自訂 Chat Completions 完成正常實網對話。這些是本機消費端證據。
兩種上游檢查（目前 pin 及明確指定同一 commit）均回傳 `YES`，其範圍是
已登錄的上游證據。

## 後續維護

上游同步時，依確切候選版本重新核對公開錯誤契約，將此欄位的存續作為獨立的
跨儲存庫決策。如果有等價的結構化錯誤可供辨認，先讓 SwiftChat 改用該介面，
再移除本地欄位。移除前須重跑原始及包裝後的斷線案例，確認失敗分類、即時串流
和工具執行次數符合原先的回歸斷言。
