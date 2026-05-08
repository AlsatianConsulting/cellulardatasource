package dev.alsatianconsulting.cellulardatasource

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.util.Log
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.IOException
import java.io.OutputStreamWriter
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger

internal class JsonStreamServer(
    private val getRunning: () -> Boolean,
    private val getPayload: () -> JSONObject?,
    private val appendHealth: (JSONObject) -> Unit,
    private val broadcast: (String) -> Unit,
    private val clientPool: Executor,
) {
    companion object {
        private const val TAG = "JsonStreamServer"
        const val SOCKET_NAME = "cellstream_data"
    }

    val activeClients = AtomicInteger(0)
    @Volatile var lastWriteMs = 0L
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
                Log.w(TAG, "stream accept error, retrying", exc)
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
                    val payload = getPayload()
                    if (payload != null) {
                        val now = System.currentTimeMillis()
                        lastWriteMs = now
                        lastActivityMs = now
                        appendHealth(payload)
                        val text = payload.toString()
                        out.write(text)
                        out.newLine()
                        out.flush()
                        broadcast(text)
                    }
                } catch (exc: IOException) {
                    break
                } catch (exc: Exception) {
                    Log.w(TAG, "stream client write error", exc)
                    break
                }
                if (!safeSleep(2000)) break
            }
        } catch (exc: Exception) {
            Log.w(TAG, "stream client setup failed", exc)
        } finally {
            try { sock.close() } catch (exc: IOException) { Log.w(TAG, "close stream client failed", exc) }
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
            Log.w(TAG, "close stream server socket failed", exc)
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
