import Foundation

/// Sunrise and sunset for one calendar day at one place.
struct SunTimes: Equatable, Sendable {
    /// Nil when the sun doesn't cross the horizon that day.
    var sunrise: Date?
    var sunset: Date?
    /// The sun stays above the horizon all day (midnight sun).
    var isPolarDay: Bool
    /// The sun stays below the horizon all day.
    var isPolarNight: Bool
}

/// NOAA's sunrise/sunset algorithm (the one behind the NOAA Solar Calculator), in pure code.
/// Accurate to about a minute between ±72° latitude; uses the standard -0.833° refraction-corrected
/// horizon. Longitude is positive east of Greenwich.
enum SolarCalculator {
    /// Sun times for the calendar day containing `date` in `calendar`'s time zone.
    static func sunTimes(on date: Date, latitude: Double, longitude: Double,
                                calendar: Calendar = .current) -> SunTimes {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return sunTimes(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1,
                        latitude: latitude, longitude: longitude)
    }

    /// Sun times for a calendar date (the event nearest that date's local solar day).
    static func sunTimes(year: Int, month: Int, day: Int, latitude: Double, longitude: Double) -> SunTimes {
        let lat = max(-89.999, min(89.999, latitude))
        let lon = longitude.truncatingRemainder(dividingBy: 360)
        let jd = julianDay(year: year, month: month, day: day)
        let midnightUTC = Date(timeIntervalSince1970: (jd - 2440587.5) * 86400)
        let rise = eventMinutesUTC(rising: true, jd: jd, latitude: lat, longitude: lon)
        let set = eventMinutesUTC(rising: false, jd: jd, latitude: lat, longitude: lon)
        var times = SunTimes(sunrise: nil, sunset: nil, isPolarDay: false, isPolarNight: false)
        switch (rise, set) {
        case let (.minutes(r), .minutes(s)):
            times.sunrise = midnightUTC.addingTimeInterval(r * 60)
            times.sunset = midnightUTC.addingTimeInterval(s * 60)
        case (.alwaysUp, _), (_, .alwaysUp):
            times.isPolarDay = true
        case (.alwaysDown, _), (_, .alwaysDown):
            times.isPolarNight = true
        }
        return times
    }

    /// Julian Day at 0h UTC of a Gregorian calendar date.
    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year, m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = (Double(y) / 100).rounded(.down)
        let b = 2 - a + (a / 4).rounded(.down)
        return (365.25 * Double(y + 4716)).rounded(.down) + (30.6001 * Double(m + 1)).rounded(.down)
            + Double(day) + b - 1524.5
    }

    enum Event: Equatable {
        case minutes(Double)
        case alwaysUp
        case alwaysDown
    }

    /// Minutes after 0h UTC of the date. Like NOAA, a second pass re-evaluates the sun's position
    /// at the first estimate's moment; the result still counts from the same midnight.
    static func eventMinutesUTC(rising: Bool, jd: Double, latitude: Double, longitude: Double) -> Event {
        let first = eventUTC(rising: rising, jd: jd, latitude: latitude, longitude: longitude)
        guard case .minutes(let estimate) = first else { return first }
        let refined = eventUTC(rising: rising, jd: jd + estimate / 1440, latitude: latitude, longitude: longitude)
        if case .minutes = refined { return refined }
        return first
    }

    private static func eventUTC(rising: Bool, jd: Double, latitude: Double, longitude: Double) -> Event {
        let t = julianCentury(jd)
        let eqTime = equationOfTime(t)
        let declination = sunDeclination(t)
        let latRad = radians(latitude), decRad = radians(declination)
        let cosHA = cos(radians(90.833)) / (cos(latRad) * cos(decRad)) - tan(latRad) * tan(decRad)
        if cosHA > 1 { return .alwaysDown }
        if cosHA < -1 { return .alwaysUp }
        var hourAngle = degrees(acos(cosHA))
        if !rising { hourAngle = -hourAngle }
        return .minutes(720 - 4 * (longitude + hourAngle) - eqTime)
    }

    // MARK: - Solar coordinates

    static func julianCentury(_ jd: Double) -> Double { (jd - 2451545.0) / 36525.0 }

    static func geomMeanLongSun(_ t: Double) -> Double {
        var l0 = 280.46646 + t * (36000.76983 + t * 0.0003032)
        l0 = l0.truncatingRemainder(dividingBy: 360)
        return l0 < 0 ? l0 + 360 : l0
    }

    static func geomMeanAnomalySun(_ t: Double) -> Double { 357.52911 + t * (35999.05029 - 0.0001537 * t) }

    static func eccentricityEarthOrbit(_ t: Double) -> Double { 0.016708634 - t * (0.000042037 + 0.0000001267 * t) }

    static func sunEquationOfCenter(_ t: Double) -> Double {
        let m = radians(geomMeanAnomalySun(t))
        return sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289
    }

    static func sunApparentLong(_ t: Double) -> Double {
        let trueLong = geomMeanLongSun(t) + sunEquationOfCenter(t)
        let omega = 125.04 - 1934.136 * t
        return trueLong - 0.00569 - 0.00478 * sin(radians(omega))
    }

    static func meanObliquityOfEcliptic(_ t: Double) -> Double {
        let seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
        return 23.0 + (26.0 + seconds / 60.0) / 60.0
    }

    static func obliquityCorrection(_ t: Double) -> Double {
        let omega = 125.04 - 1934.136 * t
        return meanObliquityOfEcliptic(t) + 0.00256 * cos(radians(omega))
    }

    static func sunDeclination(_ t: Double) -> Double {
        let e = radians(obliquityCorrection(t))
        let lambda = radians(sunApparentLong(t))
        return degrees(asin(sin(e) * sin(lambda)))
    }

    /// Equation of time in minutes.
    static func equationOfTime(_ t: Double) -> Double {
        let epsilon = radians(obliquityCorrection(t))
        let l0 = radians(geomMeanLongSun(t))
        let e = eccentricityEarthOrbit(t)
        let m = radians(geomMeanAnomalySun(t))
        var y = tan(epsilon / 2)
        y *= y
        let eTime = y * sin(2 * l0) - 2 * e * sin(m) + 4 * e * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * e * e * sin(2 * m)
        return degrees(eTime) * 4
    }

    static func radians(_ d: Double) -> Double { d * .pi / 180 }
    static func degrees(_ r: Double) -> Double { r * 180 / .pi }
}
