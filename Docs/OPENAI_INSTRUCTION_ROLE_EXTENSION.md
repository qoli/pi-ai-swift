# 維護決策：`developer` 是端點能力

**歷史決策，適用於 1.4.0。** 2026-11-12 授權的 Swift 端行為分叉，範圍是 OpenAI 相容協定的指令編碼。
決策對照基線為 `earendil-works/pi/packages/ai` 1.4.0，
commit `86dc686cf2fd795b2b24af3d614bb0e1307bcd76`。
[上游對照清單](../UpstreamMappings/pi-ai.json)在 `wire-openai-completions` 和
`wire-openai-responses` 兩處指向本紀錄。

## v1.6.0 上游同步

v1.6.0 採用上游 `faac5858` 的角色規則。Completions 在模型有 reasoning 能力且相容設定允許時送 `developer`。未指定相容設定時，上游以 provider 為 `openai` 或 base URL 字串包含 `api.openai.com` 判定。Responses 同樣要求 reasoning 能力，相容設定預設允許。判斷使用模型能力，使用者當次選的推理強度不參與角色選擇。

原版測試與 Swift 差分測試直接比對上游輸出的角色。OpenAI、Groq、SiliconFlow 的回歸案例保留。正式接收版本以 `Upstream.lock.json` 為準。

以下保留舊版分叉的背景、行為與當時的驗收結果。

## 分叉原因

鎖定的 TypeScript 上游以 `model.reasoning` 搭配相容性判斷選角色。
[Completions](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/openai-completions.ts#L1220) 使用偵測後的 `supportsDeveloperRole`；
[Responses](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/openai-responses-shared.ts#L273) 在該欄位未明確為 `false` 時視為支援。
模型能推理，並不能證明端點的訊息模板接受 `developer`。
[Groq Qwen3.8 27B 的 HTTP 400](https://github.com/earendil-works/pi/issues/10741) 就是這個差異；SiliconFlow 的 Qwen 也曾拒絕帶 `developer` 的請求。

## 1.4.0 Swift 行為

[共用的角色選擇](../Sources/PiAIProviderRuntime/Wire/Common/OpenAIInstructionRole.swift)適用於 Completions 和 Responses 的一般指令、對話中的指令更新及工具更新的文字通知。依下列順序決定：

| 條件 | 送出的角色 |
| --- | --- |
| 端點的模型相容設定明確指定 `compat.supportsDeveloperRole: false` | `system` |
| 端點的模型相容設定明確指定 `compat.supportsDeveloperRole: true` | `developer` |
| 未指定，且協定為 `openai-responses`、請求 URL 精確等於 `https://api.openai.com/v1/responses` | `developer`，依官方端點明定的支援 |
| 其他情況 | `system` |

角色不受模型的推理能力、思考開關或推理強度影響。Groq 和 SiliconFlow 走同一個預設規則，維護時不靠新增供應商例外修補。
Responses 的 `additional_tools` 是另一種結構化項目；只有相容設定同時啟用 `supportsMidConvoSystemMessages` 和 `supportsAdditionalTools` 才會使用，項目本身依 [OpenAI Responses API 規格](https://developers.openai.com/api/reference/resources/responses/methods/create) 固定送 `role: developer`。

## 驗收與上游差異

| 離線回歸 | 驗證內容 |
| --- | --- |
| [OpenAI Responses 與 Groq](../Tests/PiAIProviderRuntimeTests/ProviderVerticalSliceTests.swift) | OpenAI GPT-4.1 即使不具推理能力也送 `developer`；Groq Qwen 送 `system`，保留 `reasoning_effort: high`。 |
| [SiliconFlow](../Tests/PiAIProviderRuntimeTests/CustomProviderRuntimeTests.swift) | 思考關閉或開啟時都送 `system`，分別保留 `enable_thinking: false` 或 `true`，不送 `reasoning_effort`。 |
| [明確啟用、停用與預設](../Tests/PiAIProviderRuntimeTests/OpenAIRequestBranchClosureTests.swift) | 兩種協定都驗證有無推理能力、相容設定的優先順序，以及網址含有相似名稱的第三方端點不會被視為官方端點。 |

當時的 Swift 補充對照只在指定案例中將角色的預期值由 `developer` 改為 `system`，其餘請求欄位照原始快照比對。
原版上游斷言繼續由[完整離線驗收](../Scripts/Conformance/ci.py)執行。
在決策基線上，154 組共 2,244 項的對照有 1,346 項通過、5 項角色差異、866 項未執行、27 項超出範圍。以下 5 項仍期待 `developer`：

- [OpenRouter 的 OpenAI／Anthropic 批次指令](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/openai-completions-tool-choice.test.ts#L1175)
- [OpenAI Completions 的推理模型指令](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/openai-completions-tool-choice.test.ts#L1202)
- [折疊到首則訊息的 OpenAI 指令更新](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/transcript-tool-changes.test.ts#L374)
- [Responses 工具重定義案例中的一般指令與文字通知](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/transcript-tool-changes.test.ts#L405)
- [xAI Responses 指令](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/xai-responses.test.ts#L164)

這些是已知的分叉，原始報告仍記為 `mismatch`，所以基線上的 `offlineConformant` 為 `false`，嚴格 CI 會判定失敗。保留原版斷言和門檻，以便其他差異仍能被發現。
