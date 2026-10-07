#if DEBUG
    import AgentKit
    import Foundation
    import TermindApplication

    extension AssistantTranscriptPreview {
        /// No live store, account, network, or model service is involved in these rendering fixtures.
        public static func knowledgeCards(language: AppLanguage) -> [AgentToolCard] {
            let prose: String
            switch language {
            case .simplifiedChinese: prose = "部署之前先检查状态，并保留可复用的验证步骤。"
            case .traditionalChinese: prose = "部署之前先檢查狀態，並保留可重用的驗證步驟。"
            case .japanese: prose = "デプロイ前に状態を確認し、再利用できる検証手順を残してください。"
            case .english, .system: prose = "Check status before deploying and retain reusable verification steps."
            }
            let body = Array(repeating: prose, count: 80).joined(separator: "\n")
            let operations: AgentJSONValue = .array(
                (0..<8).map { index in
                    .object(["action": .string("update"), "name": .string("deploy-\(index)"), "content": .string(body)])
                })
            struct Sample {
                let name: String
                let symbol: String
                let arguments: [String: AgentJSONValue]
                let result: AgentJSONValue
                init(_ name: String, _ symbol: String, _ arguments: [String: AgentJSONValue], _ result: AgentJSONValue)
                {
                    self.name = name
                    self.symbol = symbol
                    self.arguments = arguments
                    self.result = result
                }
            }
            let samples: [Sample] = [
                .init(
                    "skills_list", "books.vertical", [:],
                    .object([
                        "skills": .array(
                            (0..<15).map { index in
                                .object([
                                    "name": .string("deploy-\(index)"), "description": .string(prose),
                                    "enabled": .bool(index.isMultiple(of: 2)), "read_only": .bool(index == 0),
                                ])
                            })
                    ])),
                .init(
                    "skill_read_file", "book.closed", ["name": .string("deploy")],
                    .object([
                        "skill": .string("deploy"), "path": .string("SKILL.md"), "title": .string("Deploy"),
                        "content": .string(body),
                    ])),
                .init(
                    "skill_manage", "book.closed", ["operations": operations],
                    .object([
                        "saved": .bool(true), "available": .string("next_run"),
                    ])),
                .init(
                    "skill_install", "square.and.arrow.down", ["name": .string("deploy")],
                    .object([
                        "saved": .bool(true), "name": .string("deploy"),
                        "source": .string("https://github.com/example/skills/tree/main/deploy"),
                        "available": .string("next_run"),
                    ])),
                .init(
                    "memory", "brain",
                    [
                        "operations": .array([
                            .object([
                                "action": .string("add"), "target": .string("user"), "content": .string(prose),
                            ])
                        ])
                    ], .object(["memory": .string("MEMORY\n" + body)])),
                .init(
                    "session_search", "magnifyingglass", ["query": .string("deploy")],
                    .object([
                        "messages": .array(
                            (0..<8).map { index in
                                .object([
                                    "title": .string("Deploy \(index)"),
                                    "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                                    "content": .string(body), "conversation_id": .string("not-visible"),
                                ])
                            }), "next_offset": .number(8),
                    ])),
            ]
            return samples.map { sample in
                let name = sample.name
                var card = AgentToolCard(
                    invocation: .init(
                        runID: UUID(), call: .init(id: name, name: name, arguments: .object(sample.arguments))),
                    descriptor: .init(
                        name: name, summary: name, inputSchema: .object([:]), target: .local, approvalPolicy: .approve,
                        presentation: .init(
                            symbol: sample.symbol, activity: .semanticLabel(.skill),
                            presenterID: "builtin.\(name)", actionKind: .write)), state: .completed)
                card.result = AgentToolResult(callID: name, content: sample.result.encodedString)
                return card
            }
        }
    }
#endif
