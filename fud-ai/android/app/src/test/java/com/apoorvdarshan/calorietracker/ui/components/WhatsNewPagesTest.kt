package com.apoorvdarshan.calorietracker.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class WhatsNewPagesTest {
    private val everyone = listOf(WhatsNewPage.LIVE_VOICE, WhatsNewPage.SUPPORT, WhatsNewPage.DEVELOPER)
    private val withAccess = listOf(WhatsNewPage.LIVE_VOICE, WhatsNewPage.ACCESS, WhatsNewPage.SUPPORT, WhatsNewPage.DEVELOPER)

    @Test
    fun `an unchecked subscription leaves out the access page`() {
        assertEquals(everyone, WhatsNewPages.pages(null))
    }

    @Test
    fun `subscribers skip the access page`() {
        assertEquals(everyone, WhatsNewPages.pages(WhatsNewAccess(canBuyPlans = false, needsLiveVoiceSetup = false)))
    }

    @Test
    fun `getting Live Voice follows the video`() {
        assertEquals(withAccess, WhatsNewPages.pages(WhatsNewAccess(canBuyPlans = true, needsLiveVoiceSetup = false)))
        assertEquals(withAccess, WhatsNewPages.pages(WhatsNewAccess(canBuyPlans = false, needsLiveVoiceSetup = true)))
        assertEquals(withAccess, WhatsNewPages.pages(WhatsNewAccess(canBuyPlans = true, needsLiveVoiceSetup = true)))
    }
}
