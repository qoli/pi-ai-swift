# OpenCode Go 缺少 session header 的修復筆記

## 故障與上游行為

SwiftChat Dev 使用 OpenCode Go 的 Gemini 4 Argon · High 送出新對話的第一則
訊息時，收到 HTTP 400。OpenCode 的回應類型是 `MissingSessionID`。同一組
憑證、模型、推理等級與請求內容，只補上 `x-opencode-session` 後，原生
Swift 與 TypeScript 都能取得 HTTP 200 並完成串流。OpenCode Go 以這個欄位
做對話路由與 prompt cache 識別。[OpenCode Go 的 session 規格](https://dev.opencode.ai/docs/console/harnesses/#sessions)

接受版本為 `86dc686cf2fd795b2b24af3d614bb0e1307bcd76`（pi-ai 1.4.0）。
上游提交 `561a2e06` 自 0.86.0 起會把呼叫端的 `sessionId` 投影為
`x-opencode-session`。上游 `a4ccccbd`（1.5.0）延續同一規則。Pi CLI
從自己的 session manager 提供這個值，SwiftChat 的送訊路徑則未傳入既有的
對話 ID。[上游修復](https://github.com/earendil-works/pi/commit/561a2e066c0742e3d3e33c75d5d32a69b1d89194)
· [1.5.0 的 header 投影](https://github.com/earendil-works/pi/blob/a4ccccbd64d4ccea1644f5a07bb94ef09075b219/packages/ai/src/providers/opencode-headers.ts#L9-L25)
· [Pi CLI 的 session 來源](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/coding-agent/src/core/sdk.ts#L411-L428)

## 本地擴充

這是使用者授權的 Class C 本地請求行為擴充。共用的
`ProviderSessionHeaders.applyOpenCode` 在原始請求送出前決定 header，涵蓋
OpenCode Go 目前使用的 Gemini、Anthropic Messages、OpenAI Chat Completions
和 Responses 路徑。[請求投影](../Sources/PiAIProviderRuntime/Wire/Common/ProviderSessionHeaders.swift)

1. 保留既有的 `x-opencode-session`。呼叫端可用任意大小寫指定這個 header，
   也可用 `nil` 明確抑制它。
2. 呼叫端提供非空的 `ProviderGenerationOptions.sessionID` 時，送出該值。
3. 其餘 OpenCode Go 請求以 `ProviderRequest.id` 的 SHA-256 十六進位摘要作為
   路由 ID。重送相同的 request ID 會用相同摘要。空 request ID 在建構 HTTP
   請求時取得新的 UUID。

SDK 預設只知道請求的身分。要讓同一對話跨回合共用路由及快取，由呼叫端把
穩定的對話 ID 傳到 `sessionID`。OpenCode Zen 仍依明確的 header 或 session ID
決定是否送出該欄位。

## 驗證

`swift test --filter ProviderVerticalSliceTests` 使用實際的
`BuiltinProviderRuntime.stream`，由合成 transport 在缺少 header 時回
`400 MissingSessionID`，具備 header 時送出各協定的合成串流。Gemini 4 Argon、
Claude Haiku 5.5、DeepSeek V4.1 Flash 和 GPT 5.6 Luna 四案在修復前都收到
400，修復後都產生文字與完成事件。另核對同一 request ID 的穩定性、不同
request ID 的隔離、空 ID、明確指定和抑制 header，以及 Zen 的作用範圍。
[Swift 回歸案例](../Tests/PiAIProviderRuntimeTests/ProviderVerticalSliceTests.swift)

同一份 `ProviderVerticalSliceTests.swift` 在 iOS 27.0 Simulator 通過。
完整 SwiftPM 測試 target 含使用 macOS `Process` 的 Azure 測試。模擬器驗證
使用 `Scripts/ios-conformance-project.rb` 產生的暫存測試宿主，讓
`iOSConformance` target 編譯 `ProviderVerticalSliceTests.swift` 與
`FixtureHTTPBody.swift`，並執行 `-only-testing:iOSConformance/ProviderVerticalSliceTests`。
`PiAIProviderRuntime` 的 iOS Simulator 套件也通過 arm64 與 x86_64 編譯。

macOS 完整 `swift test` 使用接受版本產生的 schema 6 目錄，262 項通過。

使用 SwiftChat 本機專案連結修復後的套件，以 `xcodebuild` 重建原本簽署的
macOS SwiftChat Dev。沿用已配置的 OpenCode Go 憑證，從正常輸入框對
Gemini 4 Argon · High 發送兩輪合成訊息，兩輪都有可見的文字回覆與正常
串流終止事件。這組實測涵蓋 macOS 本機開發版的單一模型。

目前 pin 與指定同一 revision 的兩個 `Scripts/check-upstream.sh` 檢查都回傳
`YES`。用 `Scripts/Conformance/run.py` 對照原版
`opencode-provider-headers.test.ts`、`identity.test.ts` 與
`google-thinking-level-map.test.ts`，31 項均通過並有 Swift 執行證據。
請求級路由 ID 由本地回歸案例驗證。上游對照報告的通過範圍是上述三組案例。

## 後續維護

每次上游同步都先查候選版的 OpenCode session 投影。把本地預設與上游原版
fixture 分開驗證。上游原版套件若提供等效的路由 ID，或所有消費端都能為
各回合帶入穩定的對話 ID，再檢視能否移除本地擴充。移除前重跑有無
`sessionID`、header 優先權及四種協定的案例，並以 Dev App 的正常送訊流程
確認 OpenCode Go 仍能完成串流。
