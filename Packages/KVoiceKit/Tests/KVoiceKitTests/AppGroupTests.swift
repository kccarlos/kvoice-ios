import Testing
@testable import KVoiceKit

@Test func appGroupIdentifierHasGroupPrefix() {
    #expect(AppGroup.identifier.hasPrefix("group."))
}
