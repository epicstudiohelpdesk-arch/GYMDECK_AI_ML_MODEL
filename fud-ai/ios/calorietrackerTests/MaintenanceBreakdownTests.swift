import Testing
@testable import calorietracker

struct MaintenanceBreakdownTests {
    /// Katch-McArdle (body fat known) keeps BMR independent of age, so the TDEE is fixed:
    /// (370 + 21.6 × 0.8 × 80) × 1.2 = 2102.88.
    private func makeProfile(goal: WeightGoal, weeklyChangeKg: Double? = nil, customCalories: Int? = nil) -> UserProfile {
        var profile = UserProfile.default
        profile.weightKg = 80
        profile.bodyFatPercentage = 0.20
        profile.activityLevel = .sedentary
        profile.goal = goal
        profile.weeklyChangeKg = weeklyChangeKg
        profile.customCalories = customCalories
        return profile
    }

    @Test func maintenanceIsTruncatedFormulaTDEE() {
        let breakdown = makeProfile(goal: .maintain).maintenanceBreakdown

        #expect(breakdown.maintenanceCalories == 2_102)
        #expect(breakdown.targetCalories == 2_102)
        #expect(breakdown.dailyDifference == 0)
        #expect(breakdown.balance == .maintenance)
    }

    @Test func formulaGainTargetShowsWeeklyRateSurplus() {
        let profile = makeProfile(goal: .gain, weeklyChangeKg: 0.25)
        let breakdown = profile.maintenanceBreakdown

        #expect(breakdown.dailyDifference == profile.calorieAdjustment)
        #expect(breakdown.dailyDifference == 275)
        #expect(breakdown.balance == .surplus)
    }

    @Test func formulaLoseTargetShowsWeeklyRateDeficit() {
        let breakdown = makeProfile(goal: .lose, weeklyChangeKg: 0.5).maintenanceBreakdown

        #expect(breakdown.dailyDifference == -550)
        #expect(breakdown.balance == .deficit)
    }

    @Test func customCalorieTargetIsComparedAsFollowed() {
        let breakdown = makeProfile(goal: .maintain, customCalories: 2_600).maintenanceBreakdown

        #expect(breakdown.maintenanceCalories == 2_102)
        #expect(breakdown.targetCalories == 2_600)
        #expect(breakdown.dailyDifference == 498)
        #expect(breakdown.balance == .surplus)
    }

    @Test func smallDifferencesReadAsMaintenance() {
        let tolerance = MaintenanceBreakdown.maintenanceTolerance

        #expect(MaintenanceBreakdown(maintenanceCalories: 2_000, targetCalories: 2_000 - tolerance + 1).balance == .maintenance)
        #expect(MaintenanceBreakdown(maintenanceCalories: 2_000, targetCalories: 2_000 + tolerance - 1).balance == .maintenance)
        #expect(MaintenanceBreakdown(maintenanceCalories: 2_000, targetCalories: 2_000 - tolerance).balance == .deficit)
        #expect(MaintenanceBreakdown(maintenanceCalories: 2_000, targetCalories: 2_000 + tolerance).balance == .surplus)
    }
}
