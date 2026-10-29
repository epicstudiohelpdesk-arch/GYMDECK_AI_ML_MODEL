package com.apoorvdarshan.calorietracker.services.voice

import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

class LivePlaybackDrainTest {
    @Test fun aFinalChunkEnqueuedDuringTheDrainCheckRemainsPlaying() {
        val lock = Any()
        val playing = AtomicBoolean(true)
        val queue = LinkedBlockingQueue<ByteArray>()
        val written = AtomicLong(480)
        val attemptEnqueue = CountDownLatch(1)
        val enqueueStarted = CountDownLatch(1)
        val enqueueFinished = CountDownLatch(1)
        val writer = Thread {
            if (attemptEnqueue.await(5, TimeUnit.SECONDS)) {
                enqueueStarted.countDown()
                synchronized(lock) {
                    playing.set(true)
                    queue.offer(byteArrayOf(1, 2))
                }
                enqueueFinished.countDown()
            }
        }
        writer.start()
        try {
            assertTrue(markLivePlaybackDrained(lock, playing, queue, written) {
                // Pause at the exact old race: the empty queue was observed, but the
                // playback-head read and playing=false transition have not finished.
                assertTrue("The whole drain decision must hold the enqueue lock", Thread.holdsLock(lock))
                attemptEnqueue.countDown()
                assertTrue(enqueueStarted.await(5, TimeUnit.SECONDS))
                assertEquals(1L, enqueueFinished.count)
                480L
            })
            assertTrue(enqueueFinished.await(5, TimeUnit.SECONDS))
            assertTrue("Turn completion must still wait for the final chunk", playing.get())
            assertEquals(1, queue.size)
            assertFalse(markLivePlaybackDrained(lock, playing, queue, written) { 480L })
        } finally {
            attemptEnqueue.countDown()
            writer.join(5_000)
            if (writer.isAlive) writer.interrupt()
        }
    }

    @Test fun queuedAndUnheardAudioPreventIdleAndDrainIsReportedOnce() {
        val lock = Any()
        val playing = AtomicBoolean(true)
        val queue = LinkedBlockingQueue<ByteArray>().apply { offer(byteArrayOf(1, 2)) }
        val written = AtomicLong(1_000)
        assertFalse(markLivePlaybackDrained(lock, playing, queue, written) { 1_000L })
        queue.clear()
        assertFalse(markLivePlaybackDrained(lock, playing, queue, written) { 500L })
        assertTrue(playing.get())
        assertTrue(markLivePlaybackDrained(lock, playing, queue, written) { 1_000L })
        assertFalse(playing.get())
        assertFalse(markLivePlaybackDrained(lock, playing, queue, written) { 1_000L })
    }
}
