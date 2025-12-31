import Foundation
import StoreKit

@MainActor
final class DJAIStore: ObservableObject {
    enum Access: Equatable {
        case locked
        case subscribed
        case lifetime
    }

    enum History: Equatable {
        case unknown
        case none
        case hasPurchasedSubscription
        case hasStartedTrial
    }

    struct ProductIDs: Sendable {
        let weekly: String
        let monthly: String
        let yearly: String
        let lifetime: String
        let foundersLifetime: String

        var subscriptionIDs: [String] { [weekly, monthly, yearly] }
        var lifetimeIDs: [String] { [lifetime, foundersLifetime] }
        var all: [String] { [weekly, monthly, yearly, lifetime, foundersLifetime] }

        static func `default`(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> ProductIDs {
            // Product IDs must match what you configure in App Store Connect.
            // Using bundle ID prefix makes it easy to keep them consistent across targets.
            let prefix = (bundleIdentifier?.isEmpty == false) ? bundleIdentifier! : "autoplaylistbuilder"
            return ProductIDs(
                weekly: "\(prefix).dj.ai.weekly",
                monthly: "\(prefix).dj.ai.monthly",
                yearly: "\(prefix).dj.ai.yearly",
                lifetime: "\(prefix).dj.ai.lifetime",
                foundersLifetime: "\(prefix).dj.ai.founders.lifetime"
            )
        }
    }

    @Published private(set) var access: Access = .locked
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var purchaseHistory: History = .unknown

    private let productIDs: ProductIDs
    private var updatesTask: Task<Void, Never>?

    private let foundersCutoffExclusive: Date = {
        // Founders should stop showing after 12/31/2026.
        // Use an exclusive cutoff at 01/01/2027 00:00:00 (current calendar/timezone).
        var components = DateComponents()
        components.year = 2027
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        return Calendar(identifier: .gregorian).date(from: components) ?? Date.distantPast
    }()

    init(productIDs: ProductIDs = .default()) {
        self.productIDs = productIDs
        startListeningForTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    var hasAccess: Bool {
        switch access {
        case .locked: return false
        case .subscribed, .lifetime: return true
        }
    }

    func configure() async {
        await refreshEntitlements()
        await refreshPurchaseHistory()
        await loadProducts()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: productIDs.all)
            products = loaded.sorted(by: sortProducts)
            lastErrorMessage = nil
        } catch {
            products = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        do {
            lastErrorMessage = nil
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                _ = try Self.requireVerified(verification)
                await refreshEntitlements()
            case .pending:
                // User needs to complete approval (e.g. Ask to Buy)
                break
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            lastErrorMessage = nil
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var foundLifetime = false
        var foundSubscription = false

        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.requireVerified(entitlement) else { continue }
            guard transaction.revocationDate == nil else { continue }

            let productID = transaction.productID
            if productIDs.lifetimeIDs.contains(productID) {
                foundLifetime = true
                break
            }

            if productIDs.subscriptionIDs.contains(productID) {
                // If expirationDate is nil, treat as active (shouldn’t happen for auto-renewable)
                if let expiration = transaction.expirationDate {
                    if expiration > Date() {
                        foundSubscription = true
                    }
                } else {
                    foundSubscription = true
                }
            }
        }

        if foundLifetime {
            access = .lifetime
        } else if foundSubscription {
            access = .subscribed
        } else {
            access = .locked
        }
    }

    var subscriptionProducts: [Product] {
        products.filter { productIDs.subscriptionIDs.contains($0.id) }
    }

    var lifetimeProduct: Product? {
        products.first(where: { $0.id == productIDs.lifetime })
    }

    var foundersLifetimeProduct: Product? {
        products.first(where: { $0.id == productIDs.foundersLifetime })
    }

    var shouldShowFoundersLifetime: Bool {
        let now = Date()
        guard now < foundersCutoffExclusive else { return false }

        switch purchaseHistory {
        case .unknown:
            // If we haven't loaded history yet, keep it hidden to avoid accidentally offering founders.
            return false
        case .none:
            return true
        case .hasPurchasedSubscription, .hasStartedTrial:
            return false
        }
    }

    var preferredLifetimeProduct: Product? {
        if shouldShowFoundersLifetime, let foundersLifetimeProduct {
            return foundersLifetimeProduct
        }
        return lifetimeProduct
    }

    func displayName(for product: Product) -> String {
        switch product.id {
        case productIDs.weekly:
            return L10n.DJAI.planWeekly
        case productIDs.monthly:
            return L10n.DJAI.planMonthly
        case productIDs.yearly:
            return L10n.DJAI.planYearly
        case productIDs.foundersLifetime:
            return L10n.DJAI.planFoundersLifetime
        case productIDs.lifetime:
            return L10n.DJAI.planLifetime
        default:
            return product.displayName
        }
    }

    private func startListeningForTransactions() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await update in Transaction.updates {
                guard let _ = try? Self.requireVerified(update) else { continue }
                await self.refreshEntitlements()
                await self.refreshPurchaseHistory()
            }
        }
    }

    private func refreshPurchaseHistory() async {
        // Rule: stop showing founders after user started a trial OR purchased any DJ AI subscription.
        // We infer this from StoreKit transaction history.

        var hasPurchasedSubscription = false
        var hasStartedTrial = false

        // Scan full transaction history (including expired subscriptions).
        for await result in Transaction.all {
            guard let transaction = try? Self.requireVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }

            let productID = transaction.productID
            if productIDs.subscriptionIDs.contains(productID) {
                hasPurchasedSubscription = true

                // If this subscription transaction was an introductory offer, treat it as "started trial".
                // Note: offerType/offerID may be nil depending on how the purchase was made.
                if transaction.offerType == .introductory {
                    hasStartedTrial = true
                }
            }

            if hasStartedTrial {
                break
            }
        }

        if hasStartedTrial {
            purchaseHistory = .hasStartedTrial
        } else if hasPurchasedSubscription {
            purchaseHistory = .hasPurchasedSubscription
        } else {
            purchaseHistory = .none
        }
    }

    private func sortProducts(_ lhs: Product, _ rhs: Product) -> Bool {
        func rank(_ product: Product) -> Int {
            switch product.id {
            case productIDs.weekly: return 0
            case productIDs.monthly: return 1
            case productIDs.yearly: return 2
            case productIDs.foundersLifetime: return 3
            case productIDs.lifetime: return 4
            default: return 99
            }
        }
        return rank(lhs) < rank(rhs)
    }

    private static func requireVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified(_, let error):
            throw error
        }
    }
}
