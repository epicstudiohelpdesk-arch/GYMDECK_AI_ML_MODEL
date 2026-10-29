package com.apoorvdarshan.calorietracker.ui.voice

import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The orb's AGSL is only compiled by the device's Skia, so a mistake would silently fall
 * back to the Canvas orb. Compiling it here (with every uniform set) catches that.
 */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = Build.VERSION_CODES.TIRAMISU)
class LiveOrbShaderTest {
    @Test
    fun orbShaderCompilesWithItsUniforms() {
        OrbShader.compile()
    }
}
