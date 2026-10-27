import ActivityKit
import Foundation
import KVoiceCore

/// The Live Activity for a dictation. Compiled into the app (which starts
/// and updates it) and the widget extension (which draws it); never into
/// the keyboard.
struct DictationActivityAttributes: ActivityAttributes {
    typealias ContentState = DictationLiveStatus

    /// The `DictationActivity.id` of the recording this activity mirrors.
    var sessionID: UUID
}
