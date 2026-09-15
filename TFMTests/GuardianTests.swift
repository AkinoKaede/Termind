import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct GuardianHostTests {
    @Test
    func guardianCacheKeyIsStablePerConversation() throws {
        let id = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        #expect(
            TermindAgentPolicy.guardianCacheKey(conversationID: id)
                == "guardian:12345678-1234-1234-1234-123456789abc"
        )
    }

}
