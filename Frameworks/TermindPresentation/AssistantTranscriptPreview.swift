#if DEBUG
    import AgentKit
    import Foundation
    import TermindApplication

    /// The same deterministic content exercises both native transcript renderers.
    @MainActor
    public enum AssistantTranscriptPreview {
        public enum Phase: String, CaseIterable {
            case thinking, tools, results
        }

        public static func work(language: AppLanguage, phase: Phase, now: Date = .now) -> AgentWorkGroup {
            let conversation = ConversationModel.demo(language: language)
            var group = conversation.workGroups[0]
            group.run.startedAt = now.addingTimeInterval(-65)
            group.run.finishedAt = phase == .results ? now : nil
            group.run.state = phase == .results ? .completed : .running
            let reasoning =
                switch language {
                case .simplifiedChinese:
                    "**检查上游服务。**\n先读取 `nginx` 日志，再核对监听端口；暂不更改配置。"
                case .traditionalChinese:
                    "**檢查上游服務。**\n先讀取 `nginx` 日誌，再核對監聽連接埠；暫不變更設定。"
                case .system, .english:
                    "**Inspect the upstream service.**\nRead the `nginx` logs, then check listening ports before changing configuration."
                }
            if phase == .thinking {
                let block = AgentReasoningBlock(text: reasoning, createdAt: now)
                group.items = [.reasoning(block)]
                group.activeReasoningBlockID = block.id
            } else {
                var cards = conversation.toolCards
                cards[0].state = phase == .tools ? .running : .completed
                cards[1].state = phase == .tools ? .completed : .failed
                cards[0].result = AgentToolResult(
                    callID: cards[0].invocation.call.id,
                    content: "Active: active (running)\nMain PID: 421 (nginx)"
                )
                let failure =
                    switch language {
                    case .simplifiedChinese: "连接上游服务失败：连接被拒绝。"
                    case .traditionalChinese: "連線至上游服務失敗：連線遭拒。"
                    case .system, .english: "connect() failed: connection refused"
                    }
                cards[1].result = AgentToolResult(
                    callID: cards[1].invocation.call.id,
                    content: failure,
                    isError: phase == .results
                )
                group.items = [
                    .tools(
                        .init(
                            cards: cards, runID: group.id,
                            reasoning: phase == .tools ? .init(sourceMessageID: UUID(), markdown: reasoning) : nil
                        ))
                ]
                group.activeReasoningBlockID = nil
            }
            return group
        }
    }
#endif
