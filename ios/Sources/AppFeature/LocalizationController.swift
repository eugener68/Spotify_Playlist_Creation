import Foundation
import Combine

enum LocalizationOption: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var languageCode: String? {
        switch self {
        case .system:
            return nil
        case .english, .russian:
            return rawValue
        }
    }

    fileprivate var storageValue: String {
        switch self {
        case .system:
            return "system"
        case .english:
            return "en"
        case .russian:
            return "ru"
        }
    }

    fileprivate init?(storageValue: String?) {
        guard let storageValue else { return nil }
        switch storageValue {
        case "system": self = .system
        case "en": self = .english
        case "ru": self = .russian
        default: return nil
        }
    }
}

final class LocalizationController: ObservableObject {
    static let shared = LocalizationController()

    @Published var selection: LocalizationOption {
        didSet {
            persist(selection)
            bundle = LocalizationController.bundle(for: selection)
        }
    }

    private let storageKey = "app.localization.selection"
    private var bundle: Bundle

    private init() {
        let persisted = LocalizationOption(storageValue: UserDefaults.standard.string(forKey: storageKey)) ?? .system
        selection = persisted
        bundle = LocalizationController.bundle(for: persisted)
    }

    func localizedString(forKey key: String, comment: String) -> String {
        bundle.localizedString(forKey: key, value: "", table: nil)
    }

    private func persist(_ option: LocalizationOption) {
        if option == .system {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(option.storageValue, forKey: storageKey)
        }
    }

    private static func bundle(for option: LocalizationOption) -> Bundle {
        guard let code = option.languageCode,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .module
        }
        return bundle
    }
}
