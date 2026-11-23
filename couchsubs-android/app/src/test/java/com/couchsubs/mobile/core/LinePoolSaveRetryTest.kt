// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LinePoolSaveRetryTest {
    @Test
    fun failedDiskWriteKeepsUnsentQueueForTheNextSave() {
        val root = Files.createTempDirectory("line-pool-retry").toFile()
        try {
            // An existing file cannot be used as a directory. Saving initially
            // fails with IOException, but the in-memory queue must stay dirty.
            val parent = File(root, "blocked")
            parent.writeText("not a directory")
            val state = File(parent, "queue.json")
            val pool = LinePool(file = state, app = "test", clock = { 1_000_000L })
            pool.offer("Keep moving now.")
            assertEquals(1, pool.queued.size)
            assertFalse(state.exists())

            // Once the filesystem recovers, a second save must persist the line
            // even if no new subtitles have been offered.
            assertTrue(parent.delete())
            assertTrue(parent.mkdir())
            pool.save()
            assertTrue("Failed write must be retried", state.isFile)
            val restored = LinePool(file = state, app = "test", clock = { 1_000_000L })
            assertEquals(pool.queued.map { it.key }, restored.queued.map { it.key })
        } finally {
            root.deleteRecursively()
        }
    }
}
