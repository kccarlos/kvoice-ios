import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@Test func appGroupIdentifierHasGroupPrefix() {
    #expect(AppGroup.identifier.hasPrefix("group."))
}
