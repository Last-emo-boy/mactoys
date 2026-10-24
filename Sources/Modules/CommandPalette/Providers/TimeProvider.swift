import AppKit
import MacToysCore

/// Time & Date: current time, world clocks, Unix timestamps, ISO 8601, calendar weeks.
@MainActor
final class TimeProvider: SearchProvider {
    let id = "time"
    let name = "Time & Date"
    let summary = "Current time and date, other time zones, Unix timestamps and calendar weeks"
    let icon = ItemIcon.symbol("clock.fill", .orange)
    let defaultKeyword = ")"
    let examples = ["time", "time in Tokyo", "unix 1792852868", "week::2026-10-24", "unix::2026-10-24 10:30", "iso"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(subtitle: "Time, date and time zones", keywords: ["clock", "timezone", "world clock", "calendar"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        guard let q = TimeQuery.parse(query.text, scoped: query.scoped) else { return [] }
        return items(for: q, now: Date(), zone: .current, locale: .current, scoped: query.scoped)
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        if id == "time:now" { return items(for: .now(.time), now: Date(), zone: .current, locale: .current, scoped: false).first }
        return nil
    }

    // MARK: Items

    func items(for q: TimeQuery, now: Date, zone: TimeZone, locale: Locale, scoped: Bool) -> [PaletteItem] {
        let o = engine.options.value
        let custom = TimeFormats.Custom.parse(o.timeCustomFormats)
        let time = TimeFormats.formatter(time: o.timeShowSeconds ? .medium : .short, zone: zone, locale: locale)
        let fullDate = TimeFormats.formatter(date: .full, zone: zone, locale: locale)
        let rows = TimeFormats.rows(for: now, zone: zone, locale: locale, custom: custom)
        let city = TimeZoneLookup.city(of: zone)
        let detail = ItemDetails(icon: icon, title: time.string(from: now), largeTitle: true, subtitle: fullDate.string(from: now),
                                 rows: rows.prefix(scoped ? rows.count : 4).map(DetailRow.init))

        switch q {
        case .now(let focus):
            var list: [PaletteItem] = []
            let main = copyItem("time:now", title: time.string(from: now), subtitle: "\(fullDate.string(from: now)) · \(city)",
                                copy: time.string(from: now), score: 990, details: detail)
            let dateItem = copyItem("time:date", title: fullDate.string(from: now), subtitle: "Today · \(city)",
                                    copy: fullDate.string(from: now), score: 985, details: detail, symbol: "calendar")
            func rowItem(_ label: String, score: Double) -> PaletteItem? {
                rows.first { $0.label == label }.map {
                    copyItem("time:\(label)", title: $0.value, subtitle: label, copy: $0.value, score: score, details: detail,
                             symbol: "number")
                }
            }
            switch focus {
            case .date: list = [dateItem, main]
            case .unix: list = [rowItem("Unix", score: 995), rowItem("Unix (ms)", score: 994)].compactMap { $0 } + [main]
            case .iso: list = [rowItem("ISO 8601", score: 995)].compactMap { $0 } + [main]
            case .week: list = [rowItem("Week", score: 995)].compactMap { $0 } + [main, dateItem]
            case .utc: list = [rowItem("UTC", score: 995)].compactMap { $0 } + [main]
            case .time: list = [main]
            case .all:
                list = [main, dateItem] + rows.enumerated().compactMap { i, r in rowItem(r.label, score: 980 - Double(i)) }
            }
            if focus == .time || focus == .all {
                list += o.worldClocks.compactMap(TimeZone.init(identifier:)).filter { $0.identifier != zone.identifier }
                    .enumerated().map { i, tz in clockItem(tz, label: TimeZoneLookup.city(of: tz), now: now, local: zone,
                                                           locale: locale, score: 970 - Double(i)) }
            }
            return list
        case .zone(let tz, let label):
            return [clockItem(tz, label: label, now: now, local: zone, locale: locale, score: 990, withDate: true)]
        case .instant(let date):
            let dt = TimeFormats.formatter(date: .full, time: .medium, zone: zone, locale: locale).string(from: date)
            let r = TimeFormats.rows(for: date, zone: zone, locale: locale, custom: custom)
            let rel = RelativeDateTimeFormatter()
            rel.locale = locale
            let relative = rel.localizedString(for: date, relativeTo: now)
            let d = ItemDetails(icon: icon, title: TimeFormats.formatter(time: .medium, zone: zone, locale: locale).string(from: date),
                                largeTitle: true, subtitle: TimeFormats.formatter(date: .full, zone: zone, locale: locale).string(from: date),
                                rows: r.map(DetailRow.init))
            var list = [copyItem("time:instant", title: dt, subtitle: "\(relative) · \(city)", copy: dt, score: 990, details: d)]
            list += r.enumerated().map { i, row in
                copyItem("time:instant:\(row.label)", title: row.value, subtitle: row.label, copy: row.value,
                         score: 980 - Double(i), details: d, symbol: "number")
            }
            return list
        case .week(let date):
            let w = TimeFormats.isoWeek(date, in: zone)
            let dateText = TimeFormats.formatter(date: .long, zone: zone, locale: locale).string(from: date)
            return [copyItem("time:week", title: "Week \(w.week) of \(w.of)", subtitle: "\(dateText) · ISO 8601 week, \(w.year)",
                             copy: String(w.week), score: 990, details: detail, symbol: "calendar")]
        case .unixOf(let date):
            let v = TimeFormats.unix(date)
            let dateText = TimeFormats.formatter(date: .long, time: .medium, zone: zone, locale: locale).string(from: date)
            return [copyItem("time:unix", title: v, subtitle: "Unix timestamp of \(dateText)", copy: v, score: 990,
                             details: detail, symbol: "number"),
                    copyItem("time:unixms", title: String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))),
                             subtitle: "Unix timestamp in milliseconds", copy: String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))),
                             score: 985, details: detail, symbol: "number")]
        }
    }

    private func clockItem(_ tz: TimeZone, label: String, now: Date, local: TimeZone, locale: Locale, score: Double,
                           withDate: Bool = false) -> PaletteItem {
        let t = TimeFormats.formatter(time: .short, zone: tz, locale: locale).string(from: now)
        let offset = TimeFormats.offsetLabel(tz.secondsFromGMT(for: now))
        let diff = TimeFormats.difference(tz, from: local, at: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = local
        var otherCal = Calendar(identifier: .gregorian)
        otherCal.timeZone = tz
        let dayShift = otherCal.component(.day, from: now) != cal.component(.day, from: now)
        let dateText = TimeFormats.formatter(date: .full, zone: tz, locale: locale).string(from: now)
        var subtitle = "\(offset) · \(diff)"
        if withDate || dayShift { subtitle += " · \(TimeFormats.formatter("EEE d MMM", zone: tz, locale: locale).string(from: now))" }
        let details = ItemDetails(icon: .symbol("globe", .blue), title: TimeFormats.formatter(time: .medium, zone: tz, locale: locale).string(from: now),
                                  largeTitle: true, subtitle: "\(dateText) · \(label)",
                                  rows: TimeFormats.rows(for: now, zone: tz, locale: locale).prefix(4).map(DetailRow.init) + [
                                      DetailRow(label: "Offset", value: offset),
                                      DetailRow(label: "Difference", value: diff, monospaced: false),
                                  ])
        return PaletteItem(
            id: "time:zone:\(tz.identifier)", title: "\(t) in \(label)", subtitle: subtitle, icon: .symbol("globe", .blue),
            providerID: id, accessory: "Clock", score: score,
            primary: PaletteAction(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                Launch.copy("\(t) \(label)")
                HUD.show("Copied \(t) \(label)", symbol: "doc.on.doc")
                return .dismiss
            },
            details: details, isPinnable: false)
    }

    private func copyItem(_ id: String, title: String, subtitle: String, copy: String, score: Double,
                          details: ItemDetails, symbol: String = "clock.fill") -> PaletteItem {
        PaletteItem(
            id: id, title: title, subtitle: subtitle, icon: .symbol(symbol, .orange), providerID: self.id, accessory: "Copy",
            score: score,
            primary: PaletteAction(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                Launch.copy(copy)
                HUD.show("Copied \(copy)", symbol: "doc.on.doc")
                return .dismiss
            },
            actions: [PaletteAction(id: "paste", title: "Paste", symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                Launch.pasteOutcome(copy)
            }],
            details: details, isPinnable: id == "time:now")
    }
}

extension DetailRow {
    init(_ row: TimeFormats.Row) { self.init(label: row.label, value: row.value) }
}
