import Foundation

/// CSS for previews: GitHub-like light and dark palettes, code, Markdown and data tables.
public enum Styles {
    private static let light = """
    --bg:#ffffff; --fg:#1f2328; --muted:#59636e; --border:#d1d9e0; --subtle:#f6f8fa; --accent:#0969da;
    --ln:#8c959f; --sel:#dbe9f9; --kw:#cf222e; --ty:#953800; --fn:#8250df; --lit:#0550ae; --str:#0a3069;
    --num:#0550ae; --com:#6e7781; --meta:#8250df; --tag:#116329; --an:#0550ae; --var:#953800;
    --prop:#0550ae; --head:#0550ae; --ins-fg:#116329; --ins-bg:#dafbe1; --del-fg:#82071e; --del-bg:#ffebe9;
    --re:#116329; --esc:#cf222e; --row:#f6f8fa;
    """

    private static let dark = """
    --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --border:#3d444d; --subtle:#151b23; --accent:#4493f8;
    --ln:#6e7681; --sel:#1f3a5f; --kw:#ff7b72; --ty:#ffa657; --fn:#d2a8ff; --lit:#79c0ff; --str:#a5d6ff;
    --num:#79c0ff; --com:#8b949e; --meta:#d2a8ff; --tag:#7ee787; --an:#79c0ff; --var:#ffa657;
    --prop:#79c0ff; --head:#79c0ff; --ins-fg:#aff5b4; --ins-bg:#033a16; --del-fg:#ffdcd7; --del-bg:#67060c;
    --re:#7ee787; --esc:#ff7b72; --row:#151b23;
    """

    /// CSS custom properties for the theme (both palettes behind a media query for `.auto`).
    public static func palette(_ theme: PreviewTheme) -> String {
        switch theme {
        case .light: ":root { \(light) }"
        case .dark: ":root { \(dark) }"
        case .auto: ":root { \(light) }\n@media (prefers-color-scheme: dark) { :root { \(dark) } }"
        }
    }

    static let base = """
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
    body { font: var(--font-size)/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
           -webkit-font-smoothing: antialiased; }
    ::selection { background: var(--sel); }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    """

    /// Source code listings (see `CodeRenderer`).
    public static let code = """
    body.code-page { padding: 0; }
    .code { display: table; min-width: 100%; border-collapse: collapse; padding: 8px 0;
            font: var(--font-size)/1.5 ui-monospace, "SF Mono", Menlo, monospace; tab-size: 4; }
    .code .l { display: table-row; height: 1.5em; }
    .code.ln .l::before { content: attr(data-n); display: table-cell; text-align: right; padding: 0 14px 0 12px;
            color: var(--ln); -webkit-user-select: none; user-select: none; position: sticky; left: 0;
            background: var(--bg); width: 1%; white-space: nowrap; }
    .code .c { display: table-cell; white-space: pre; padding: 0 16px 0 12px; }
    .code.ln .c { padding-left: 4px; }
    .code.wrap .c { white-space: pre-wrap; overflow-wrap: anywhere; }
    .notice { font: 12px -apple-system, sans-serif; color: var(--muted); padding: 10px 16px;
              border-bottom: 1px solid var(--border); background: var(--subtle); }
    \(tokens)
    """

    /// Token colors shared by listings and Markdown code blocks.
    static let tokens = """
    .kw { color: var(--kw); } .ty { color: var(--ty); } .fn { color: var(--fn); } .bi { color: var(--fn); }
    .lit { color: var(--lit); } .str { color: var(--str); } .num { color: var(--num); }
    .com { color: var(--com); font-style: italic; } .meta { color: var(--meta); } .at { color: var(--meta); }
    .tag { color: var(--tag); } .an { color: var(--an); } .av { color: var(--str); } .var { color: var(--var); }
    .prop { color: var(--prop); } .head { color: var(--head); font-weight: 600; } .sec { color: var(--fn); font-weight: 600; }
    .ins { color: var(--ins-fg); background: var(--ins-bg); } .del { color: var(--del-fg); background: var(--del-bg); }
    .re { color: var(--re); } .esc { color: var(--esc); } .em { font-style: italic; } .strong { font-weight: 600; }
    .link { color: var(--accent); }
    """

    /// GitHub-flavored Markdown article.
    public static let markdown = """
    .markdown-body { box-sizing: border-box; max-width: 900px; margin: 0 auto; padding: 28px 36px 48px;
                     word-wrap: break-word; }
    .markdown-body > *:first-child { margin-top: 0 !important; }
    .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 {
        margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    .markdown-body h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    .markdown-body h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    .markdown-body h3 { font-size: 1.25em; } .markdown-body h4 { font-size: 1em; }
    .markdown-body h5 { font-size: .875em; } .markdown-body h6 { font-size: .85em; color: var(--muted); }
    .markdown-body p, .markdown-body blockquote, .markdown-body ul, .markdown-body ol, .markdown-body dl,
    .markdown-body table, .markdown-body pre, .markdown-body details { margin: 0 0 16px; }
    .markdown-body blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    .markdown-body blockquote > :last-child { margin-bottom: 0; }
    .markdown-body ul, .markdown-body ol { padding-left: 2em; }
    .markdown-body li + li { margin-top: .25em; }
    .markdown-body li > p { margin-top: 16px; }
    .markdown-body li > ul, .markdown-body li > ol { margin-bottom: 0; }
    .markdown-body li.task { list-style: none; }
    .markdown-body li.task > input { margin: 0 .35em .2em -1.4em; vertical-align: middle; }
    .markdown-body hr { height: .25em; padding: 0; margin: 24px 0; background: var(--border); border: 0; }
    .markdown-body img { max-width: 100%; box-sizing: content-box; }
    .markdown-body code { font: 85% ui-monospace, "SF Mono", Menlo, monospace; padding: .2em .4em;
                          background: var(--subtle); border-radius: 6px; }
    .markdown-body pre { padding: 16px; overflow: auto; font-size: 85%; line-height: 1.45;
                         background: var(--subtle); border-radius: 6px; }
    .markdown-body pre code { padding: 0; background: transparent; font-size: 100%; border-radius: 0;
                              white-space: pre; }
    .markdown-body table { border-spacing: 0; border-collapse: collapse; display: block; width: max-content;
                           max-width: 100%; overflow: auto; }
    .markdown-body th { font-weight: 600; }
    .markdown-body th, .markdown-body td { padding: 6px 13px; border: 1px solid var(--border); }
    .markdown-body tr:nth-child(2n) { background: var(--row); }
    .markdown-body del { color: var(--muted); }
    .markdown-body kbd { font: 11px ui-monospace, Menlo, monospace; padding: 3px 5px; border: 1px solid var(--border);
                         border-bottom-width: 2px; border-radius: 6px; background: var(--subtle); }
    .markdown-body .footnotes { font-size: 12px; color: var(--muted); border-top: 1px solid var(--border);
                                margin-top: 32px; padding-top: 12px; }
    .markdown-body .img-blocked { display: inline-block; padding: 2px 8px; border: 1px dashed var(--border);
                                  border-radius: 6px; color: var(--muted); font-size: 12px; }
    .markdown-body .anchor { float: left; margin-left: -20px; padding-right: 4px; opacity: 0; color: var(--muted); }
    .markdown-body h1:hover .anchor, .markdown-body h2:hover .anchor, .markdown-body h3:hover .anchor { opacity: 1; }
    \(tokens)
    """

    /// Data tables (CSV/TSV, SQLite).
    public static let table = """
    .grid-wrap { overflow: auto; }
    table.grid { border-collapse: separate; border-spacing: 0; font: 12px -apple-system, sans-serif; min-width: 100%; }
    table.grid th, table.grid td { padding: 5px 10px; border-bottom: 1px solid var(--border);
                                   border-right: 1px solid var(--border); white-space: nowrap; text-align: left;
                                   max-width: 420px; overflow: hidden; text-overflow: ellipsis; }
    table.grid thead th { position: sticky; top: 0; background: var(--subtle); font-weight: 600; z-index: 1; }
    table.grid td.n, table.grid th.n { color: var(--ln); text-align: right; background: var(--subtle);
                                       position: sticky; left: 0; font-variant-numeric: tabular-nums; }
    table.grid thead th.n { z-index: 2; }
    table.grid tr:nth-child(2n) td:not(.n) { background: var(--row); }
    table.grid td.num { text-align: right; font-variant-numeric: tabular-nums; }
    table.grid td.null { color: var(--muted); font-style: italic; }
    table.grid td.blob { color: var(--meta); }
    """
}
