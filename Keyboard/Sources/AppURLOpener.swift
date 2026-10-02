import UIKit

/// Opens `kvoice://` from the keyboard extension.
///
/// Keyboards have no supported way to open their containing app:
/// `extensionContext?.open(_:completionHandler:)` only works for Today-style
/// widgets and always reports failure in a keyboard, and `UIApplication.shared`
/// is unavailable to extensions (`APPLICATION_EXTENSION_API_ONLY`). The
/// extension process still has a `UIApplication` at the end of the responder
/// chain, so this walks the chain to it and calls
/// `open(_:options:completionHandler:)` through its Objective-C selector
/// (three arguments, so through its IMP; `perform(_:with:with:)` can't pass
/// them). The legacy `openURL:` is a last resort: current iOS refuses it.
/// This needs Full Access and must be re-checked on device with every iOS
/// release; it is isolated here so it is easy to replace.
@MainActor
enum AppURLOpener {
    static func open(_ url: URL, from responder: UIResponder, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        var current: UIResponder? = responder
        while let next = current {
            // `is UIApplication`, not a `responds(to:)` check: `UIScene` also
            // sits in the chain and has a same-named method with another
            // options type.
            if let application = next as? UIApplication {
                if openModern(url, application: application, completion: completion) { return }
                openLegacy(url, application: application, completion: completion)
                return
            }
            current = next.next
        }
        completion(false)
    }

    private static func openModern(
        _ url: URL,
        application: UIApplication,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: selector) else { return false }
        typealias OpenFunction = @convention(c) (
            AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
        ) -> Void
        let function = unsafeBitCast(application.method(for: selector), to: OpenFunction.self)
        let handler: @convention(block) (Bool) -> Void = { success in
            Task { @MainActor in completion(success) }
        }
        function(application, selector, url as NSURL, NSDictionary(), handler)
        return true
    }

    private static func openLegacy(
        _ url: URL,
        application: UIApplication,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let selector = NSSelectorFromString("openURL:")
        guard application.responds(to: selector) else {
            completion(false)
            return
        }
        // The result is not reliable; the keyboard's open timeout catches a
        // silent refusal.
        _ = application.perform(selector, with: url)
        completion(true)
    }
}
