package dev.alsatianconsulting.cellulardatasource

import android.location.Location
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs

internal object NmeaFormat {
    fun sentences(location: Location, satellites: Int?): List<String> {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"), Locale.US)
        val time = "%02d%02d%02d".format(
            cal.get(Calendar.HOUR_OF_DAY),
            cal.get(Calendar.MINUTE),
            cal.get(Calendar.SECOND)
        )
        val date = "%02d%02d%02d".format(
            cal.get(Calendar.DAY_OF_MONTH),
            cal.get(Calendar.MONTH) + 1,
            cal.get(Calendar.YEAR) % 100
        )
        val lat = coord(location.latitude, true)
        val lon = coord(location.longitude, false)
        val ns = if (location.latitude >= 0) "N" else "S"
        val ew = if (location.longitude >= 0) "E" else "W"
        val sats = (satellites ?: 0).coerceIn(0, 99)
        val hdop = if (location.hasAccuracy()) {
            "%.1f".format(Locale.US, (location.accuracy / 5.0).coerceAtLeast(0.8))
        } else {
            "1.0"
        }
        val alt = if (location.hasAltitude()) "%.1f".format(Locale.US, location.altitude) else "0.0"
        val speedKnots = if (location.hasSpeed()) location.speed * 1.94384449 else 0.0
        val bearing = if (location.hasBearing()) location.bearing else 0.0f
        val gga = "GPGGA,$time,$lat,$ns,$lon,$ew,1,%02d,$hdop,$alt,M,0.0,M,,".format(Locale.US, sats)
        val rmc = "GPRMC,$time,A,$lat,$ns,$lon,$ew,%.1f,%.1f,$date,,,A".format(Locale.US, speedKnots, bearing)
        return listOf(withChecksum(gga), withChecksum(rmc))
    }

    private fun coord(value: Double, isLat: Boolean): String {
        val absValue = abs(value)
        val degrees = absValue.toInt()
        val minutes = (absValue - degrees) * 60.0
        return if (isLat) "%02d%07.4f".format(Locale.US, degrees, minutes)
        else "%03d%07.4f".format(Locale.US, degrees, minutes)
    }

    private fun withChecksum(sentence: String): String {
        var checksum = 0
        sentence.forEach { checksum = checksum xor it.code }
        return "\$$sentence*%02X".format(Locale.US, checksum)
    }
}
