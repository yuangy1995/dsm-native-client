package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class FileDownloadExecutionLockTest {
    @Test fun sameDestinationWaitsForCloseWhileOtherDownloadsRemainIndependent() = runTest {
        val firstOpened = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var secondOpened = false
        val first = launch { withDownloadDestination("content://synthetic/a") {
            firstOpened.complete(Unit)
            withContext(NonCancellable) { release.await() }
        } }
        firstOpened.await()
        first.cancel()
        val second = launch { withDownloadDestination("content://synthetic/a") { secondOpened = true } }
        withDownloadDestination("content://synthetic/b") { yield() }
        assertFalse(secondOpened)
        release.complete(Unit); first.join(); second.join()
        assertTrue(secondOpened)
        withDownloadDestination("content://synthetic/a") { assertTrue(secondOpened) }
    }
}
