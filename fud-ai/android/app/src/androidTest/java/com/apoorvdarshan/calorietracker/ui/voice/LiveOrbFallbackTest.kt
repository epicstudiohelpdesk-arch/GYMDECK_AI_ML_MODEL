package com.apoorvdarshan.calorietracker.ui.voice

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Exercise the production pre-Android-13 renderer, including on newer CI devices. */
class LiveOrbFallbackTest {
    @get:Rule val compose = createComposeRule()

    @Test fun transparentFilamentsStayVisibleOnLightBackground() = assertVisibleOn(Color.White)

    @Test fun transparentFilamentsStayVisibleOnDarkBackground() = assertVisibleOn(Color.Black)

    private fun assertVisibleOn(background: Color) {
        compose.setContent {
            Box(Modifier.size(120.dp).background(background).testTag("orbSurface")) {
                FallbackLiveOrb(
                    frame = LiveOrbFrame(active = 1f),
                    tint = Color(0xFFFF2D55),
                    modifier = Modifier.fillMaxSize(),
                    clearBackground = true
                )
            }
        }
        val pixels = compose.onNodeWithTag("orbSurface").captureToImage().toPixelMap()
        val corner = pixels[0, 0]
        assertEquals(background.red, corner.red, 0.02f)
        assertEquals(background.green, corner.green, 0.02f)
        assertEquals(background.blue, corner.blue, 0.02f)
        var colored = 0
        for (y in 0 until pixels.height step 2) {
            for (x in 0 until pixels.width step 2) {
                val color = pixels[x, y]
                if (color.red - color.green > 0.03f) colored++
            }
        }
        assertTrue("Expected visible pink filaments; found $colored colored pixels", colored > 20)
    }
}
