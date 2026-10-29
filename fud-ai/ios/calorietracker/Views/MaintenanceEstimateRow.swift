import SwiftUI

/// Read-only Daily Targets row showing the formula maintenance estimate (BMR × activity) and the
/// daily deficit or surplus of the calorie target against it. Tapping explains how it's estimated.
struct MaintenanceEstimateRow: View {
    let profile: UserProfile

    @State private var showInfo = false
    @AppStorage(EnergyUnit.storageKey) private var energyUnit = EnergyUnit.defaultUnit

    var body: some View {
        let breakdown = profile.maintenanceBreakdown
        Button {
            showInfo = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(AppColors.calorie)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated Maintenance")
                        .foregroundStyle(.primary)
                    balanceText(breakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(energyUnit.format(kcal: breakdown.maintenanceCalories))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alert("Estimated Maintenance", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Estimated maintenance is the calories you would burn on a typical day: your BMR from your profile multiplied by your activity level. Eating below it is a deficit for losing weight; eating above it is a surplus for gaining. The deficit or surplus shown is your calorie target minus this estimate. It is a formula estimate, so your real burn can differ, and goal recalculation may set your target from your logged food, weight trend or measured energy burn instead. This is not medical advice.")
        }
    }

    private func balanceText(_ breakdown: MaintenanceBreakdown) -> Text {
        let amount = energyUnit.format(kcal: abs(breakdown.dailyDifference))
        switch breakdown.balance {
        case .deficit:
            return Text("Deficit: \(amount)/day")
        case .surplus:
            return Text("Surplus: \(amount)/day")
        case .maintenance:
            return Text("Target is close to maintenance")
        }
    }
}
