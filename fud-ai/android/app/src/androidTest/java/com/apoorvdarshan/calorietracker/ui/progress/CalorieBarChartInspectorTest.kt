package com.apoorvdarshan.calorietracker.ui.progress

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.ui.theme.FudAITheme
import java.time.LocalDate
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The calorie chart's tap inspector must keep working when its data changes in place. */
@RunWith(AndroidJUnit4::class)
class CalorieBarChartInspectorTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun tapInspectsAnotherPeriodWithTheSameBarCount() {
        // Values stay under 1,000 so the expected text has no locale-specific separator.
        val monday = LocalDate.of(2026, 1, 12)
        val thisWeek = (0L until 7L).map { monday.plusDays(it) to 610 + it.toInt() * 10 }
        val lastWeek = (0L until 7L).map { monday.minusDays(7 - it) to 810 + it.toInt() * 10 }
        var days by mutableStateOf(thisWeek)
        compose.setContent { FudAITheme { CalorieBarChart(dailyCalories = days, goal = 2_000) } }

        // Seven centred bars put the middle one (index 3) under the chart's centre.
        compose.onNodeWithTag(CHART).performTouchInput { click(center) }
        compose.onNodeWithText(kcal(thisWeek[3].second)).assertIsDisplayed()

        // Like stepping 1W back a period: same bar count and width, new data.
        compose.runOnIdle { days = lastWeek }
        compose.onNodeWithText(kcal(thisWeek[3].second)).assertDoesNotExist()

        compose.onNodeWithTag(CHART).performTouchInput { click(center) }
        compose.onNodeWithText(kcal(lastWeek[3].second)).assertIsDisplayed()
    }

    private fun kcal(value: Int) = context.getString(R.string.kcal_value_format, value)

    private companion object {
        const val CHART = "progress.calorieChart"
    }
}
