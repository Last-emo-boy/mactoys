import Foundation

/// File names for clippings, archives and files moved into a folder.
enum ShelfNaming {
    /// Characters a file name can't contain or shouldn't start with.
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.components(separatedBy: .newlines).joined(separator: " ")
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `name`, or "name 2.ext", "name 3.ext"… — the first that isn't in `existing` (case-insensitive,
    /// as on APFS). Like Finder, the number goes before the extension.
    static func unique(_ name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let (base, ext) = split(name)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// The archive name for compressing `names`: "Report.pdf.zip" for one item, "Archive.zip" for
    /// several (`archive` is the localized word), numbered when the folder already has one.
    static func zipName(for names: [String], archive: String = "Archive", existing: Set<String> = []) -> String {
        let base = names.count == 1 ? names[0] : archive
        return unique(base + ".zip", existing: existing)
    }

    /// "Meeting notes Thursday.txt" from the first line of the text (at most 40 characters, cut at a
    /// word), or "Text Clipping.txt" when there are no words.
    static func textClippingName(_ text: String, fallback: String = String(localized: "Text Clipping", comment: "File name for text dropped on a shelf")) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = sanitize(firstLine)
        if title.count > 40 {
            let cut = title.prefix(40)
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 12 {
                title = String(cut[..<space])
            } else {
                title = String(cut)
            }
            title = title.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        return (title.isEmpty ? fallback : title) + ".txt"
    }

    /// "Image 2026-11-04 at 14.32.07.png", like screenshots.
    static func imageClippingName(date: Date, ext: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d at %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return String(localized: "Image \(stamp)", comment: "File name for an image dropped on a shelf; the placeholder is a date and time") + "." + ext
    }

    /// "Apple Developer.webloc" from the page title, or the host name.
    static func linkClippingName(_ url: URL, title: String?) -> String {
        let fromTitle = sanitize(title ?? "")
        let base = fromTitle.isEmpty ? (url.host() ?? url.absoluteString) : String(fromTitle.prefix(60))
        let clean = sanitize(base)
        return (clean.isEmpty ? String(localized: "Link", comment: "File name for a web link dropped on a shelf") : clean) + ".webloc"
    }

    private static func split(_ name: String) -> (String, String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        // "archive.tar.gz"-style double extensions are rare on shelves; split at the last dot only,
        // and treat a leading-dot or extension-only name as having no extension.
        guard !ext.isEmpty, ns.deletingPathExtension.count > 0 else { return (name, "") }
        return (ns.deletingPathExtension, ext)
    }
}
