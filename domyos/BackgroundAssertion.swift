//
//  BackgroundAssertion.swift
//  domyos
//
//  Short-lived UIApplication background task assertion helper.
//

import UIKit

@MainActor
final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // The expiration handler is invoked on the main thread.
            MainActor.assumeIsolated { [self] in end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
