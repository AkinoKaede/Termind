import AgentKit
import Foundation

func agentSecret(_ value: String) -> AgentSecret {
    var bytes = Data(value.utf8)
    return AgentSecret(consumingUTF8: &bytes)
}
