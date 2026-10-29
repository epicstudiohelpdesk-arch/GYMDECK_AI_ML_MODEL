package com.apoorvdarshan.calorietracker.ui.settings

import com.apoorvdarshan.calorietracker.models.AddMenuConfig
import com.apoorvdarshan.calorietracker.models.AddMenuGroupConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AddMenuGroupCountTest {
    private val mixed = AddMenuConfig(
        groups = listOf(AddMenuGroupConfig(id = "g1", name = "Scan", methods = listOf("camera"))),
        flatMethods = listOf("voice")
    )

    @Test
    fun addingAGroupKeepsItInTheEditorAndKeepsStandaloneMethods() {
        val updated = updateGroupCount(mixed, 2).sanitized(forEditor = true)
        assertEquals(2, updated.groups.size)
        assertTrue(updated.groups[1].methods.isEmpty())
        assertEquals(listOf("voice"), updated.flatMethods)
    }

    @Test
    fun removingAllGroupsMovesTheirMethodsBeforeTheStandaloneOnes() {
        val updated = updateGroupCount(mixed, 0)
        assertTrue(updated.groups.isEmpty())
        assertEquals(listOf("camera", "voice"), updated.flatMethods)
    }

    @Test
    fun firstGroupWrapsTheFlatMenu() {
        val flat = AddMenuConfig(groups = emptyList(), flatMethods = listOf("camera", "voice"))
        val updated = updateGroupCount(flat, 1)
        assertEquals(listOf("camera", "voice"), updated.groups.single().methods)
        assertTrue(updated.flatMethods.isEmpty())
    }
}
