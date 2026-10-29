//
//  TipJarView.swift
//  calorietracker
//

import SwiftUI
import RevenueCat

/// The four tip products, their store prices and purchase state, shared by the
/// Settings tip rows and the What's New support page. Tips are consumable IAPs
/// that fund development; everything in the app is already unlocked, so they
/// grant nothing.
@Observable
final class TipJarStore {
    struct Tier: Identifiable {
        let productID: String
        let icon: String
        let name: String
        var id: String { productID }
    }

    static let tiers: [Tier] = [
        Tier(productID: "com.apoorvdarshan.calorietracker.tip.snack",
             icon: "tip_snack", name: String(localized: "Snack")),
        Tier(productID: "com.apoorvdarshan.calorietracker.tip.proteinshake",
             icon: "tip_proteinshake", name: String(localized: "Protein Shake")),
        Tier(productID: "com.apoorvdarshan.calorietracker.tip.lunch",
             icon: "tip_lunch", name: String(localized: "Lunch")),
        Tier(productID: "com.apoorvdarshan.calorietracker.tip.feast",
             icon: "tip_feast", name: String(localized: "Feast"))
    ]

    var products: [String: StoreProduct] = [:]
    var isLoading = true
    var purchasingID: String?
    var didTip = false

    func loadIfNeeded() async {
        if products.isEmpty { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard Purchases.isConfigured else { return }
        let fetched = await Purchases.shared.products(Self.tiers.map(\.productID))
        products = Dictionary(uniqueKeysWithValues: fetched.map { ($0.productIdentifier, $0) })
    }

    func purchase(_ product: StoreProduct) async {
        purchasingID = product.productIdentifier
        defer { purchasingID = nil }
        do {
            let result = try await Purchases.shared.purchase(product: product)
            if !result.userCancelled {
                didTip = true
            }
        } catch {
            // Cancelled or failed — the tip buttons simply stay usable.
        }
    }
}

/// Compact food-themed tip rows shown immediately before About in Settings.
struct TipJarSettingsSection: View {
    @State private var tipJar = TipJarStore()

    var body: some View {
        Section("Leave a Tip") {
            ForEach(TipJarStore.tiers) { tier in
                tierRow(tier)
            }
        }
        .listRowBackground(AppColors.appCard)
        .task {
            await tipJar.loadIfNeeded()
        }
        .alert("Thank you!", isPresented: $tipJar.didTip) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Your support keeps Fud AI free for everyone.")
        }
    }

    @ViewBuilder
    private func tierRow(_ tier: TipJarStore.Tier) -> some View {
        let product = tipJar.products[tier.productID]
        Button {
            if let product { Task { await tipJar.purchase(product) } }
        } label: {
            HStack(spacing: 10) {
                // PixelLab-generated pixel art; .none interpolation keeps pixels crisp.
                Image(tier.icon)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text(tier.name)
                    .foregroundStyle(.primary)
                Spacer()
                if tipJar.purchasingID == tier.productID || (product == nil && tipJar.isLoading) {
                    ProgressView()
                } else if let product {
                    Text(product.localizedPriceString)
                        .foregroundStyle(AppColors.calorie)
                } else {
                    // Store unreachable (offline, or products still propagating).
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(product == nil || tipJar.purchasingID != nil)
    }
}
