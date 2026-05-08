package dev.alsatianconsulting.cellulardatasource

import android.location.Location
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.util.Log
import java.io.BufferedWriter
import java.io.IOException
import java.io.OutputStreamWriter
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger

internal class NmeaStreamServer(
    private val getRunning: () -> Boolean,
    private val getLastFix: () -> Location?,
    private val getSatellites: () -> Int?,
    private val clientPool: Executor,
) {
    companion object {
        private const val TAG = "NmeaStreamServer"
        const val SOCKET_NAME = "cellstream_nmea"
    }

    val activeClients = AtomicInteger(0)
    @Volatile var lastActivityMs = 0L

    @Volatile private var serverSocket: LocalServerSocket? = null

    fun run() {
        while (getRunning()) {
            try {
                val server = ensureSocket()
                val client = server.accept()
                activeClients.incrementAndGet()
                lastActivityMs = System.currentTimeMillis()
                clientPool.execute { handleClient(client) }
            } catch (exc: IOException) {
                if (!getRunning()) break
                Log.w(TAG, "nmea accept error, retrying", exc)
                closeSocket()
                if (!safeSleep(500)) break
            }
        }
        closeSocket()
    }

    fun close() {
        closeSocket()
    }

    private fun handleClient(sock: LocalSocket) {
        try {
            val out = BufferedWriter(OutputStreamWriter(sock.outputStream))
            while (getRunning()) {
                try {
                    val fix = getLastFix()
                    if (fix != null && fix.latitude != 0.0 && fix.longitude != 0.0) {
                        for (line in NmeaFormat.sentences(fix, getSatellites())) {
                            out.write(line)
                            out.newLine()
                        }
                        out.flush()
                        lastActivityMs = System.currentTimeMillis()
                    }
                } catch (exc: IOException) {
                    break
                } catch (exc: Exception) {
                    Log.w(TAG, "nmea client write error", exc)
                    break
                }
                if (!safeSleep(1000)) break
            }
        } catch (exc: Exception) {
            Log.w(TAG, "nmea client setup failed", exc)
        } finally {
            try { sock.close() } catch (exc: IOException) { Log.w(TAG, "close nmea client failed", exc) }
            val remaining = activeClients.decrementAndGet()
            if (remaining < 0) activeClients.set(0)
        }
    }

    private fun ensureSocket(): LocalServerSocket {
        val existing = serverSocket
        if (existing != null) return existing
        val s = LocalServerSocket(SOCKET_NAME)
        serverSocket = s
        return s
    }

    private fun closeSocket() {
        try {
            serverSocket?.close()
        } catch (exc: IOException) {
            Log.w(TAG, "close nmea server socket failed", exc)
        } finally {
            serverSocket = null
        }
    }

    private fun safeSleep(ms: Long): Boolean = try {
        Thread.sleep(ms)
        true
    } catch (_: InterruptedException) {
        false
    }
}
