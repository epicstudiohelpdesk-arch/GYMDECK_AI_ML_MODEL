package com.apoorvdarshan.calorietracker.ui.home

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.apoorvdarshan.calorietracker.R
import com.apoorvdarshan.calorietracker.models.RecipeServings
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** The "Servings in recipe" stepper is usable with TalkBack and switch access (#458). */
class RecipeServingsRowTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private val isButton = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button)
    private val isPoliteLiveRegion = SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite)

    @Test fun stepButtonsAreLabeledButtonsAndTheCountIsAnnounced() {
        var servings by mutableIntStateOf(RecipeServings.MIN)
        compose.setContent {
            MaterialTheme { RecipeServingsRow(servings) { servings = it } }
        }
        val fewer = compose.onNodeWithContentDescription(context.getString(R.string.cd_recipe_servings_fewer))
        val more = compose.onNodeWithContentDescription(context.getString(R.string.cd_recipe_servings_more))

        fewer.assert(isButton).assertIsNotEnabled()
        more.assert(isButton).assertIsEnabled()
        compose.onNodeWithText("1").assert(isPoliteLiveRegion)

        more.performClick()
        compose.onNodeWithText("2").assert(isPoliteLiveRegion).assertTextEquals("2")
        fewer.assertIsEnabled()

        fewer.performClick()
        compose.runOnIdle { assertEquals(1, servings) }
        fewer.assertIsNotEnabled()

        compose.runOnIdle { servings = RecipeServings.MAX }
        more.assertIsNotEnabled()
        fewer.assertIsEnabled()
    }
}
