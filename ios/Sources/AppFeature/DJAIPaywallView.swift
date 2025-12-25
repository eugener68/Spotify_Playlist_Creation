import StoreKit
import SwiftUI

struct DJAIPaywallView: View {
    @ObservedObject var store: DJAIStore
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.DJAI.paywallTitle)
                            .font(.title2.bold())
                        Text(L10n.DJAI.paywallSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if store.isLoadingProducts {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }

                    if let message = store.lastErrorMessage, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !store.isLoadingProducts, store.products.isEmpty {
                        Text(L10n.DJAI.paywallNoPlans)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        ForEach(store.subscriptionProducts, id: \ .id) { product in
                            Button(action: { Task { await store.purchase(product) } }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(store.displayName(for: product))
                                            .font(.headline)
                                        Text(subscriptionDetailText(for: product))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(product.displayPrice)
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AccentButtonStyle())
                        }
                    }

                    if let lifetime = store.preferredLifetimeProduct {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.DJAI.paywallLifetimeHeader)
                                .font(.headline)

                            Button(action: { Task { await store.purchase(lifetime) } }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(store.displayName(for: lifetime))
                                            .font(.headline)
                                        Text(L10n.DJAI.paywallLifetimeDetail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(lifetime.displayPrice)
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }

                    Button(action: { Task { await store.restorePurchases() } }) {
                        Text(L10n.DJAI.paywallRestore)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button(action: manageSubscriptions) {
                        Text(L10n.DJAI.paywallManage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Text(L10n.DJAI.paywallDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.DJAI.paywallClose)
                }
#else
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.DJAI.paywallClose)
                }
#endif
            }
        }
        .task {
            await store.configure()
        }
    }

    private var statusText: String {
        switch store.access {
        case .locked:
            return L10n.DJAI.statusLocked
        case .subscribed:
            return L10n.DJAI.statusSubscribed
        case .lifetime:
            return L10n.DJAI.statusLifetime
        }
    }

    private func manageSubscriptions() {
        // Apple’s subscription management page.
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            openURL(url)
        }
    }

    private func subscriptionDetailText(for product: Product) -> String {
        // Intro offers (e.g. 7-day free trial) are configured in App Store Connect.
        // If present, we surface it as a hint.
        if let subscription = product.subscription {
            if subscription.introductoryOffer != nil {
                return L10n.DJAI.paywallTrialHint
            }
        }
        return L10n.DJAI.paywallCancelAnytime
    }
}
