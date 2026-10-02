import UIKit
import SwiftUI
import KVoiceCore

final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardRootView(
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        ))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 220)
        ])
        host.didMove(toParent: self)
    }
}

struct KeyboardRootView: View {
    let nextKeyboard: () -> Void

    var body: some View {
        HStack {
            Button(action: nextKeyboard) { Image(systemName: "globe") }
            Spacer()
            Image(systemName: "mic.fill").font(.largeTitle)
            Spacer()
        }
        .padding()
    }
}
