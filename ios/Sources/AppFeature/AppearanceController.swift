import Foundation
import SwiftUI

@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    @Published var forceDarkMode: Bool {
        didSet {
            persist(forceDarkMode)
        }
    }

    var preferredColorScheme: ColorScheme? {
        forceDarkMode ? .dark : nil
    }

    private let storageKey = "app.appearance.forceDarkMode"

    private init() {
        forceDarkMode = UserDefaults.standard.bool(forKey: storageKey)
    }

    private func persist(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: storageKey)
    }
}
