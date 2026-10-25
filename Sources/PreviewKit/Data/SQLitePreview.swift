import Foundation
import SQLite3

/// Read-only look into an SQLite database: tables and views, their columns, row counts and first rows.
public enum SQLitePreview {
    public struct Column: Sendable, Equatable {
        public var name: String
        public var type: String
        public var primaryKey: Bool
        public var notNull: Bool
    }

    public enum Value: Sendable, Equatable {
        case null, integer(Int64), real(Double), text(String), blob(Int)

        public var display: String {
            switch self {
            case .null: "NULL"
            case .integer(let v): String(v)
            case .real(let v): String(v)
            case .text(let s): s
            case .blob(let n): "BLOB (\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)))"
            }
        }
    }

    public struct Table: Sendable {
        public var name: String
        public var isView: Bool
        public var sql: String
        public var columns: [Column]
        public var rowCount: Int?
        public var rows: [[Value]]
    }

    public enum OpenError: Error, Equatable { case notSQLite, cannotOpen(String) }

    /// Whether the file starts with the SQLite 3 header.
    public static func isSQLite(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// Reads every table (up to `rowLimit` rows each). Never writes: the database is opened read-only,
    /// and immutable when its journal files can't be created.
    public static func read(_ url: URL, rowLimit: Int = 200) throws -> [Table] {
        guard isSQLite(url) else { throw OpenError.notSQLite }
        var db: OpaquePointer?
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var status = sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if status == SQLITE_OK, !canRead(db) { sqlite3_close(db); db = nil; status = SQLITE_CANTOPEN }
        if status != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            status = sqlite3_open_v2("file:\(path)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        }
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(db)
            throw OpenError.cannotOpen(message)
        }
        defer { sqlite3_close(db) }
        var tables: [Table] = []
        for row in query(db, "SELECT name, type, IFNULL(sql, '') FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name") {
            guard case .text(let name) = row[0], case .text(let type) = row[1], case .text(let sql) = row[2] else { continue }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let columns = query(db, "PRAGMA table_info(\(quoted))").map { r -> Column in
                func text(_ v: Value) -> String { if case .text(let s) = v { s } else { "" } }
                func int(_ v: Value) -> Int64 { if case .integer(let i) = v { i } else { 0 } }
                return Column(name: text(r[1]), type: text(r[2]), primaryKey: int(r[5]) > 0, notNull: int(r[3]) != 0)
            }
            var count: Int?
            if case .integer(let n)? = query(db, "SELECT COUNT(*) FROM \(quoted)").first?.first { count = Int(n) }
            let rows = query(db, "SELECT * FROM \(quoted) LIMIT \(rowLimit)")
            tables.append(Table(name: name, isView: type == "view", sql: sql, columns: columns, rowCount: count, rows: rows))
        }
        return tables
    }

    private static func canRead(_ db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func query(_ db: OpaquePointer, _ sql: String) -> [[Value]] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var rows: [[Value]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Value] = []
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT:
                    let s = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                    row.append(.text(s.count > 500 ? String(s.prefix(500)) + "…" : s))
                case SQLITE_BLOB: row.append(.blob(Int(sqlite3_column_bytes(stmt, i))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// A page with a table list on the left; each table's columns and rows are shown via `:target`
    /// anchors (no JavaScript), the first table by default.
    public static func page(_ tables: [Table], title: String, theme: PreviewTheme, rowLimit: Int = 200) -> String {
        let heading = String(localized: "\(tables.count) tables", comment: "Database preview: heading of the list of tables")
        var nav = "<nav class=\"tables\"><div class=\"h\">\(HTML.escape(heading))</div>"
        var sections = ""
        for (i, t) in tables.enumerated() {
            let id = "t\(i)"
            let count = t.rowCount.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) } ?? "?"
            nav += "<a href=\"#\(id)\"><span>\(t.isView ? "◇" : "▦") \(HTML.escape(t.name))</span><em>\(count)</em></a>"
            let viewBadge = String(localized: "view", comment: "Database preview: marks a view (a saved query) rather than a table")
            var s = "<section id=\"\(id)\"><h2>\(HTML.escape(t.name))\(t.isView ? " <small>\(HTML.escape(viewBadge))</small>" : "")</h2>"
            let shown = t.rows.count
            var meta = [String(localized: "\(t.columns.count) columns", comment: "Table preview: number of columns"),
                        t.rowCount.map { String(localized: "\($0) rows", comment: "Table preview: number of rows") }
                            ?? String(localized: "? rows", comment: "Database preview: the number of rows is unknown")]
            if let total = t.rowCount, total > shown {
                meta.append(String(localized: "showing the first \(shown) rows", comment: "Table preview: only the first rows are listed"))
            }
            s += "<p class=\"meta\">\(HTML.escape(meta.joined(separator: " · ")))"
            s += "</p><div class=\"grid-wrap\"><table class=\"grid\"><thead><tr><th class=\"n\"></th>"
            for c in t.columns {
                let badge = c.primaryKey ? " 🔑" : ""
                s += "<th title=\"\(HTML.escape(c.type))\">\(HTML.escape(c.name))\(badge)<br><small>\(HTML.escape(c.type.isEmpty ? String(localized: "any", comment: "Database preview: type of a column declared without a type") : c.type.lowercased()))</small></th>"
            }
            s += "</tr></thead><tbody>"
            for (r, row) in t.rows.enumerated() {
                s += "<tr><td class=\"n\">\(r + 1)</td>"
                for v in row {
                    switch v {
                    case .null: s += "<td class=\"null\">NULL</td>"
                    case .integer, .real: s += "<td class=\"num\">\(HTML.escape(v.display))</td>"
                    case .blob: s += "<td class=\"blob\">\(HTML.escape(v.display))</td>"
                    case .text: s += "<td title=\"\(HTML.escape(v.display))\">\(HTML.escape(v.display))</td>"
                    }
                }
                s += "</tr>"
            }
            s += "</tbody></table></div>"
            if !t.sql.isEmpty { s += "<pre class=\"schema\">\(HTML.escape(t.sql))</pre>" }
            s += "</section>"
            sections += s
        }
        nav += "</nav>"
        let css = Styles.table + """
        body { display: flex; height: 100vh; overflow: hidden; }
        nav.tables { width: 210px; flex: none; overflow: auto; border-right: 1px solid var(--border); background: var(--subtle);
                     font: 12px -apple-system, sans-serif; padding: 8px 0; }
        nav.tables .h { color: var(--muted); padding: 4px 14px 8px; font-weight: 600; text-transform: uppercase; font-size: 10.5px; }
        nav.tables a { display: flex; justify-content: space-between; gap: 8px; padding: 5px 14px; color: var(--fg); }
        nav.tables a:hover { background: var(--sel); text-decoration: none; }
        nav.tables a span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        nav.tables em { color: var(--muted); font-style: normal; font-variant-numeric: tabular-nums; }
        main { flex: 1; overflow: auto; }
        main section { display: none; padding: 14px 18px; }
        main section:target, main:not(:has(section:target)) section:first-of-type { display: block; }
        main h2 { margin: 0 0 2px; font-size: 16px; } main h2 small { color: var(--muted); font-weight: 400; }
        main .meta { margin: 0 0 10px; color: var(--muted); font-size: 12px; }
        main th small { color: var(--muted); font-weight: 400; }
        pre.schema { margin-top: 14px; padding: 10px 12px; background: var(--subtle); border-radius: 6px; white-space: pre-wrap;
                     font: 11.5px ui-monospace, Menlo, monospace; color: var(--muted); }
        .empty { padding: 40px; color: var(--muted); }
        """
        let empty = String(localized: "This database has no tables.")
        let main = tables.isEmpty ? "<main><div class=\"empty\">\(HTML.escape(empty))</div></main>" : "<main>\(sections)</main>"
        return HTML.document(title: title, body: nav + main, theme: theme, extraCSS: css)
    }
}
