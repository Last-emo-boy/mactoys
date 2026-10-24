import Foundation

private func w(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

private let cStrings = [StringRule("\""), StringRule("'", isCharLiteral: true)]
private let cComments: [(open: String, close: String)] = [("/*", "*/")]

private let cKeywords = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local"
private let cTypes = "char double float int long short signed unsigned void bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE wchar_t _Bool _Complex"
private let cppKeywords = cKeywords + " alignas alignof and asm catch class co_await co_return co_yield concept consteval constexpr constinit const_cast decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept not operator or override private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor"

extension Language {
    /// Every built-in language, in display order.
    public static let all: [Language] = [
        swift, c, cpp, objc, python, javascript, typescript, json, yaml, toml, xml, html, css, shell, ruby, go, rust,
        java, kotlin, csharp, php, sql, lua, perl, r, dockerfile, makefile, markdown, ini, diff, dart, scala,
        powershell, groovy, plainText,
    ]

    public static let swift: Language = {
        var l = Language(id: "swift", name: "Swift")
        l.extensions = ["swift"]
        l.keywords = w("actor any as associatedtype async await borrowing break case catch class consume consuming continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return sending set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet Self self")
        l.types = w("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Bool String Character Array Dictionary Set Optional Void Any AnyObject Never Result Error")
        l.literals = w("true false nil")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.nestedComments = true
        l.strings = [StringRule("#\"\"\"", "\"\"\"#", escapes: false, multiline: true), StringRule("\"\"\"", multiline: true),
                     StringRule("#\"", "\"#", escapes: false), StringRule("\"")]
        l.atAttributes = true
        l.capitalizedTypes = true
        l.identifierExtras = [UInt8(ascii: "$")]
        return l
    }()

    public static let c: Language = {
        var l = Language(id: "c", name: "C")
        l.extensions = ["c", "h"]
        l.keywords = w(cKeywords)
        l.types = w(cTypes)
        l.literals = w("NULL true false")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = cStrings
        l.preprocessor = true
        return l
    }()

    public static let cpp: Language = {
        var l = c
        l.id = "cpp"
        l.name = "C++"
        l.aliases = ["c++", "cxx", "hpp"]
        l.extensions = ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp", "ino"]
        l.keywords = w(cppKeywords)
        l.types = w(cTypes + " string vector map unordered_map set unique_ptr shared_ptr weak_ptr optional variant array span string_view auto")
        l.literals = w("nullptr NULL true false")
        l.strings = [StringRule("R\"(", ")\"", escapes: false, multiline: true)] + cStrings
        return l
    }()

    public static let objc: Language = {
        var l = c
        l.id = "objc"
        l.name = "Objective-C"
        l.aliases = ["objective-c", "objectivec", "obj-c", "objc++", "objective-c++"]
        l.extensions = ["m", "mm"]
        l.keywords = w(cppKeywords + " @interface @implementation @end @protocol @property @synthesize @dynamic @class @selector @encode @try @catch @finally @throw @autoreleasepool @optional @required @import self super nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull instancetype")
        l.types = w(cTypes + " id BOOL SEL IMP Class NSInteger NSUInteger CGFloat NSString NSArray NSDictionary NSNumber NSObject")
        l.literals = w("nil Nil YES NO NULL true false")
        l.strings = [StringRule("@\""), StringRule("\""), StringRule("'", isCharLiteral: true)]
        l.identifierExtras = [UInt8(ascii: "@")]
        l.capitalizedTypes = true
        return l
    }()

    public static let python: Language = {
        var l = Language(id: "python", name: "Python")
        l.aliases = ["py", "python3"]
        l.extensions = ["py", "pyw", "pyi", "pyx", "gyp"]
        l.fileNames = ["SConstruct", "SConscript"]
        l.interpreters = ["python", "python3", "python2"]
        l.keywords = w("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try type while with yield")
        l.literals = w("True False None NotImplemented Ellipsis self cls")
        l.builtins = w("abs all any ascii bin bool breakpoint bytearray bytes callable chr classmethod compile complex delattr dict dir divmod enumerate eval exec filter float format frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len list locals map max memoryview min next object oct open ord pow print property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip __import__")
        l.lineComments = ["#"]
        let p = ["r", "u", "b", "f", "br", "rb", "fr", "rf", "R", "U", "B", "F", "Br", "Rb", "BR", "RB", "Fr", "Rf", "FR", "RF"]
        l.strings = [StringRule("\"\"\"", multiline: true, prefixes: p), StringRule("'''", multiline: true, prefixes: p),
                     StringRule("\"", prefixes: p), StringRule("'", prefixes: p)]
        l.atAttributes = true
        return l
    }()

    public static let javascript: Language = {
        var l = Language(id: "javascript", name: "JavaScript")
        l.aliases = ["js", "jsx", "node", "mjs", "cjs"]
        l.extensions = ["js", "mjs", "cjs", "jsx", "es6"]
        l.interpreters = ["node", "deno", "bun"]
        l.keywords = w("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield")
        l.literals = w("true false null undefined NaN Infinity")
        l.builtins = w("Array Boolean Date Error JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap WeakSet console document window globalThis require module exports process")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
        l.identifierExtras = [UInt8(ascii: "$")]
        l.regexLiterals = true
        l.atAttributes = true
        return l
    }()

    public static let typescript: Language = {
        var l = javascript
        l.id = "typescript"
        l.name = "TypeScript"
        l.aliases = ["ts", "tsx", "mts", "cts"]
        l.extensions = ["ts", "tsx", "mts", "cts"]
        l.interpreters = ["ts-node", "tsx"]
        l.keywords = l.keywords.union(w("abstract as asserts declare enum implements infer interface is keyof module namespace override private protected public readonly satisfies type unique"))
        l.types = w("any bigint boolean never number object string symbol unknown void Record Partial Required Readonly Pick Omit Exclude Extract ReturnType Awaited")
        l.capitalizedTypes = true
        return l
    }()

    public static let json: Language = {
        var l = Language(id: "json", name: "JSON")
        l.aliases = ["jsonc", "json5", "geojson"]
        l.extensions = ["json", "jsonc", "json5", "geojson", "webmanifest", "har", "ipynb", "jsonl", "ndjson", "topojson"]
        l.fileNames = [".babelrc", ".eslintrc", ".prettierrc", "composer.lock", "Pipfile.lock"]
        l.mode = .json
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("\""), StringRule("'")]
        return l
    }()

    public static let yaml: Language = {
        var l = Language(id: "yaml", name: "YAML")
        l.aliases = ["yml"]
        l.extensions = ["yaml", "yml"]
        l.fileNames = [".clang-format", ".clang-tidy"]
        l.mode = .yaml
        l.literals = w("true false yes no on off null True False Yes No On Off Null TRUE FALSE YES NO ON OFF NULL ~")
        l.lineComments = ["#"]
        l.strings = [StringRule("\""), StringRule("'", escapes: false)]
        return l
    }()

    public static let toml: Language = {
        var l = Language(id: "toml", name: "TOML")
        l.extensions = ["toml"]
        l.fileNames = ["Cargo.lock", "Pipfile", "poetry.lock"]
        l.mode = .ini
        l.literals = w("true false inf nan")
        l.lineComments = ["#"]
        l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", escapes: false, multiline: true),
                     StringRule("\""), StringRule("'", escapes: false)]
        return l
    }()

    public static let xml: Language = {
        var l = Language(id: "xml", name: "XML")
        l.aliases = ["svg", "plist", "xsd", "xsl", "xslt", "rss", "atom", "xaml"]
        l.extensions = ["xml", "xsd", "xsl", "xslt", "plist", "svg", "rss", "atom", "xaml", "xib", "storyboard", "csproj", "vcxproj", "props", "targets", "nuspec", "resx", "kml", "gpx", "wsdl", "xliff", "xlf", "pom", "entitlements"]
        l.mode = .markup
        return l
    }()

    public static let html: Language = {
        var l = xml
        l.id = "html"
        l.name = "HTML"
        l.aliases = ["htm", "xhtml", "vue", "svelte"]
        l.extensions = ["html", "htm", "xhtml", "vue", "svelte", "jsp", "erb", "hbs", "handlebars", "mustache"]
        l.embedsScriptAndStyle = true
        return l
    }()

    public static let css: Language = {
        var l = Language(id: "css", name: "CSS")
        l.aliases = ["scss", "sass", "less", "stylus"]
        l.extensions = ["css", "scss", "sass", "less", "styl", "pcss"]
        l.mode = .css
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("\""), StringRule("'")]
        l.literals = w("inherit initial unset revert none auto transparent currentColor important")
        return l
    }()

    public static let shell: Language = {
        var l = Language(id: "shell", name: "Shell")
        l.aliases = ["sh", "bash", "zsh", "ksh", "fish", "console", "shell-session", "shellscript"]
        l.extensions = ["sh", "bash", "zsh", "ksh", "fish", "command", "tool", "bats"]
        l.fileNames = [".bashrc", ".bash_profile", ".bash_logout", ".profile", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".kshrc", "PKGBUILD", "APKBUILD", ".envrc"]
        l.interpreters = ["sh", "bash", "zsh", "ksh", "dash", "ash", "fish"]
        l.keywords = w("if then else elif fi case esac for select while until do done in function time coproc return exit break continue local export readonly declare typeset unset shift trap source alias")
        l.builtins = w("echo printf cd pwd read test eval exec set getopts wait kill jobs fg bg umask ulimit type which command builtin hash history let true false sudo grep sed awk find xargs cat ls mkdir rm cp mv chmod chown curl git make tar ssh")
        l.lineComments = ["#"]
        l.commentNeedsWordBoundary = true
        l.strings = [StringRule("\"", multiline: true), StringRule("'", escapes: false, multiline: true), StringRule("$'", "'")]
        l.variableSigils = [UInt8(ascii: "$")]
        l.functionCalls = false
        l.identifierExtras = [UInt8(ascii: "-")]
        return l
    }()

    public static let ruby: Language = {
        var l = Language(id: "ruby", name: "Ruby")
        l.aliases = ["rb", "jruby", "rake", "gemspec", "podspec"]
        l.extensions = ["rb", "rake", "gemspec", "podspec", "ru", "rbw", "jbuilder"]
        l.fileNames = ["Gemfile", "Rakefile", "Podfile", "Fastfile", "Appfile", "Brewfile", "Vagrantfile", "Guardfile", "Dangerfile", "Gemfile.lock"]
        l.interpreters = ["ruby", "jruby"]
        l.keywords = w("BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private protected public raise lambda proc loop")
        l.literals = w("true false nil __FILE__ __LINE__ __method__")
        l.builtins = w("puts print p pp format sprintf gets")
        l.lineComments = ["#"]
        l.blockComments = [("=begin", "=end")]
        l.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`")]
        l.variableSigils = [UInt8(ascii: "@"), UInt8(ascii: "$")]
        l.identifierExtras = [UInt8(ascii: "?"), UInt8(ascii: "!")]
        l.symbols = true
        l.capitalizedTypes = true
        l.regexLiterals = true
        return l
    }()

    public static let go: Language = {
        var l = Language(id: "go", name: "Go")
        l.aliases = ["golang"]
        l.extensions = ["go"]
        l.fileNames = ["go.mod", "go.sum", "go.work"]
        l.keywords = w("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
        l.types = w("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable")
        l.literals = w("true false nil iota")
        l.builtins = w("append cap clear close complex copy delete imag len make max min new panic print println real recover")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("`", escapes: false, multiline: true), StringRule("\""), StringRule("'", isCharLiteral: true)]
        return l
    }()

    public static let rust: Language = {
        var l = Language(id: "rust", name: "Rust")
        l.aliases = ["rs"]
        l.extensions = ["rs"]
        l.keywords = w("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while yield macro_rules")
        l.types = w("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc RefCell Cell HashMap HashSet BTreeMap")
        l.literals = w("true false None Some Ok Err")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.nestedComments = true
        l.strings = [StringRule("r#\"", "\"#", escapes: false, multiline: true), StringRule("r\"", "\"", escapes: false, multiline: true),
                     StringRule("\"", multiline: true, prefixes: ["b"]), StringRule("'", prefixes: ["b"], isCharLiteral: true)]
        l.hashBracketAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let java: Language = {
        var l = Language(id: "java", name: "Java")
        l.extensions = ["java", "jav"]
        l.keywords = w("abstract assert break case catch class const continue default do else enum exports extends final finally for goto if implements import instanceof interface module native new non-sealed open opens package permits private protected provides public record requires return sealed static strictfp super switch synchronized this throw throws to transient transitive try uses var void volatile when while with yield")
        l.types = w("boolean byte char double float int long short String Object Integer Long Double Boolean List Map Set")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'", isCharLiteral: true)]
        l.atAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let kotlin: Language = {
        var l = Language(id: "kotlin", name: "Kotlin")
        l.aliases = ["kt", "kts"]
        l.extensions = ["kt", "kts", "ktm"]
        l.keywords = w("abstract actual annotation as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external field final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package param private property protected public receiver reified return sealed set setparam super suspend tailrec this throw try typealias typeof val value var vararg when where while")
        l.types = w("Any Unit Nothing Int Long Short Byte Double Float Boolean Char String Array List MutableList Map Set")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.nestedComments = true
        l.strings = [StringRule("\"\"\"", escapes: false, multiline: true), StringRule("\""), StringRule("'", isCharLiteral: true)]
        l.atAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let csharp: Language = {
        var l = Language(id: "csharp", name: "C#")
        l.aliases = ["cs", "c#"]
        l.extensions = ["cs", "csx"]
        l.keywords = w("abstract add alias as ascending async await base break by case catch checked class const continue default delegate descending do dynamic else enum equals event explicit extern finally fixed for foreach from get global goto group if implicit in init interface internal into is join let lock nameof namespace new not on operator or orderby out override params partial private protected public readonly record ref remove required return scoped sealed select set sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using value var virtual volatile when where while with yield")
        l.types = w("bool byte char decimal double float int long nint nuint object sbyte short string uint ulong ushort void")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("\"\"\"", multiline: true), StringRule("@\"", "\"", escapes: false, multiline: true),
                     StringRule("$@\"", "\"", escapes: false, multiline: true), StringRule("\"", prefixes: ["$"]),
                     StringRule("'", isCharLiteral: true)]
        l.preprocessor = true
        l.capitalizedTypes = true
        return l
    }()

    public static let php: Language = {
        var l = Language(id: "php", name: "PHP")
        l.extensions = ["php", "phtml", "php3", "php4", "php5", "php7", "phps"]
        l.interpreters = ["php"]
        l.keywords = w("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield")
        l.types = w("int float bool string array object mixed void never iterable self parent")
        l.literals = w("true false null TRUE FALSE NULL")
        l.lineComments = ["//", "#"]
        l.blockComments = cComments
        l.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true)]
        l.variableSigils = [UInt8(ascii: "$")]
        l.caseInsensitive = true
        l.atAttributes = false
        return l
    }()

    public static let sql: Language = {
        var l = Language(id: "sql", name: "SQL")
        l.aliases = ["mysql", "postgresql", "psql", "plsql", "sqlite", "tsql"]
        l.extensions = ["sql", "ddl", "dml", "pgsql", "psql"]
        l.keywords = w("add all alter analyze and any as asc attach autoincrement begin between by cascade case cast check collate column commit constraint create cross current_date current_time current_timestamp database default deferrable delete desc detach distinct drop each else end escape except exclusive exists explain fail filter following for foreign from full glob group having if ignore immediate in index indexed inner insert instead intersect into is isnull join key last left like limit match natural no not nothing notnull null nulls of offset on or order outer over partition plan pragma preceding primary procedure query raise range recursive references regexp reindex release rename replace restrict returning right rollback row rows savepoint select set table temp temporary then ties to transaction trigger truncate unbounded union unique update using vacuum values view virtual when where window with without grant revoke function returns language declare")
        l.types = w("int integer smallint bigint tinyint real double float numeric decimal char varchar nvarchar text blob boolean bool date time timestamp datetime interval serial uuid json jsonb bytea")
        l.literals = w("true false null")
        l.builtins = w("count sum avg min max coalesce ifnull nullif length lower upper substr substring trim round abs now date_trunc")
        l.lineComments = ["--", "#"]
        l.blockComments = cComments
        l.strings = [StringRule("'", escapes: false, multiline: true), StringRule("\"", escapes: false), StringRule("`", escapes: false)]
        l.caseInsensitive = true
        return l
    }()

    public static let lua: Language = {
        var l = Language(id: "lua", name: "Lua")
        l.extensions = ["lua", "luau", "rockspec"]
        l.interpreters = ["lua", "luajit"]
        l.keywords = w("and break do else elseif end for function goto if in local not or repeat return then until while")
        l.literals = w("true false nil self")
        l.builtins = w("assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type xpcall string table math io os coroutine utf8")
        l.lineComments = ["--"]
        l.blockComments = [("--[[", "]]"), ("--[==[", "]==]")]
        l.strings = [StringRule("[[", "]]", escapes: false, multiline: true), StringRule("\""), StringRule("'")]
        // Block comments must be tried before the `--` line comment: the scanner checks them first.
        return l
    }()

    public static let perl: Language = {
        var l = Language(id: "perl", name: "Perl")
        l.aliases = ["pl", "pm"]
        l.extensions = ["pl", "pm", "t", "pod", "psgi"]
        l.interpreters = ["perl"]
        l.keywords = w("if elsif else unless while until for foreach do last next redo return sub my our local use no package require BEGIN END eq ne lt gt le ge cmp and or not xor qw qq q m s tr y print printf say die warn eval defined undef wantarray ref bless")
        l.lineComments = ["#"]
        l.blockComments = [("=pod", "=cut"), ("=head1", "=cut"), ("=begin", "=cut")]
        l.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`")]
        l.variableSigils = [UInt8(ascii: "$"), UInt8(ascii: "@"), UInt8(ascii: "%")]
        l.regexLiterals = true
        l.commentNeedsWordBoundary = true
        return l
    }()

    public static let r: Language = {
        var l = Language(id: "r", name: "R")
        l.aliases = ["rscript", "splus"]
        l.extensions = ["r", "rprofile"]
        l.fileNames = [".Rprofile"]
        l.interpreters = ["Rscript"]
        l.keywords = w("if else repeat while function for in next break return library require source")
        l.literals = w("TRUE FALSE NULL NA NA_integer_ NA_real_ NA_character_ Inf NaN T F")
        l.builtins = w("c list vector matrix data.frame factor print paste paste0 cat length seq rep apply lapply sapply mean sum sd")
        l.lineComments = ["#"]
        l.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`", escapes: false)]
        l.identifierExtras = [UInt8(ascii: ".")]
        return l
    }()

    public static let dockerfile: Language = {
        var l = Language(id: "dockerfile", name: "Dockerfile")
        l.aliases = ["docker", "containerfile"]
        l.extensions = ["dockerfile", "containerfile"]
        l.fileNames = ["Dockerfile", "Containerfile", "dockerfile"]
        l.keywords = w("FROM AS RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL")
        l.caseInsensitive = true
        l.lineComments = ["#"]
        l.commentNeedsWordBoundary = true
        l.strings = [StringRule("\""), StringRule("'", escapes: false)]
        l.variableSigils = [UInt8(ascii: "$")]
        l.functionCalls = false
        return l
    }()

    public static let makefile: Language = {
        var l = Language(id: "makefile", name: "Makefile")
        l.aliases = ["make", "mk", "mak"]
        l.extensions = ["mk", "mak", "make"]
        l.fileNames = ["Makefile", "makefile", "GNUmakefile", "BSDmakefile", "Kbuild"]
        l.mode = .makefile
        l.keywords = w("ifeq ifneq ifdef ifndef else endif include -include sinclude override export unexport define endef vpath .PHONY .SUFFIXES .DEFAULT .PRECIOUS .INTERMEDIATE .SECONDARY .DELETE_ON_ERROR")
        l.builtins = w("subst patsubst strip findstring filter filter-out sort word wordlist words firstword lastword dir notdir suffix basename addsuffix addprefix join wildcard realpath abspath error warning info shell origin flavor foreach if or and call eval file value")
        l.lineComments = ["#"]
        l.strings = [StringRule("\""), StringRule("'", escapes: false)]
        l.variableSigils = [UInt8(ascii: "$")]
        l.functionCalls = false
        return l
    }()

    public static let markdown: Language = {
        var l = Language(id: "markdown", name: "Markdown")
        l.aliases = ["md", "mkd", "mdown", "gfm"]
        l.extensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx", "rmd"]
        l.mode = .markdown
        return l
    }()

    public static let ini: Language = {
        var l = Language(id: "ini", name: "INI")
        l.aliases = ["cfg", "conf", "properties", "dosini", "editorconfig", "gitconfig", "env", "dotenv"]
        l.extensions = ["ini", "cfg", "conf", "properties", "prefs", "inf", "reg", "env", "editorconfig", "gitconfig", "desktop", "service", "npmrc", "pylintrc", "flake8"]
        l.fileNames = [".editorconfig", ".gitconfig", ".gitmodules", ".npmrc", ".env", ".env.local", ".env.development", ".env.production", ".flake8", "setup.cfg", "tox.ini", ".pylintrc", ".gitattributes", ".gitignore", ".dockerignore", ".npmignore", ".hgignore"]
        l.mode = .ini
        l.literals = w("true false yes no on off null")
        l.lineComments = [";", "#"]
        l.strings = [StringRule("\""), StringRule("'", escapes: false)]
        return l
    }()

    public static let diff: Language = {
        var l = Language(id: "diff", name: "Diff")
        l.aliases = ["patch", "udiff"]
        l.extensions = ["diff", "patch", "rej"]
        l.mode = .diff
        return l
    }()

    public static let dart: Language = {
        var l = Language(id: "dart", name: "Dart")
        l.extensions = ["dart"]
        l.keywords = w("abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield")
        l.types = w("int double num String bool List Map Set Future Stream Object Never dynamic")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.nestedComments = true
        l.strings = [StringRule("\"\"\"", multiline: true, prefixes: ["r"]), StringRule("'''", multiline: true, prefixes: ["r"]),
                     StringRule("\"", prefixes: ["r"]), StringRule("'", prefixes: ["r"])]
        l.atAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let scala: Language = {
        var l = Language(id: "scala", name: "Scala")
        l.aliases = ["sc", "sbt"]
        l.extensions = ["scala", "sc", "sbt"]
        l.keywords = w("abstract case catch class def do else enum export extends extension final finally for forSome given if implicit import inline lazy match new object opaque open override package private protected return sealed super then this throw trait transparent try type using val var while with yield")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.nestedComments = true
        l.strings = [StringRule("\"\"\"", escapes: false, multiline: true, prefixes: ["s", "f", "raw"]), StringRule("\"", prefixes: ["s", "f", "raw"]),
                     StringRule("'", isCharLiteral: true)]
        l.atAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let powershell: Language = {
        var l = Language(id: "powershell", name: "PowerShell")
        l.aliases = ["ps", "ps1", "pwsh", "posh"]
        l.extensions = ["ps1", "psm1", "psd1"]
        l.interpreters = ["pwsh", "powershell"]
        l.keywords = w("begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function hidden if in param process return static switch throw trap try until using var while -eq -ne -gt -ge -lt -le -like -notlike -match -notmatch -contains -notcontains -in -notin -and -or -not -is -isnot")
        l.literals = w("$true $false $null")
        l.lineComments = ["#"]
        l.blockComments = [("<#", "#>")]
        l.strings = [StringRule("@\"", "\"@", escapes: false, multiline: true), StringRule("@'", "'@", escapes: false, multiline: true),
                     StringRule("\"", multiline: true), StringRule("'", escapes: false, multiline: true)]
        l.variableSigils = [UInt8(ascii: "$")]
        l.identifierExtras = [UInt8(ascii: "-")]
        l.caseInsensitive = true
        return l
    }()

    public static let groovy: Language = {
        var l = Language(id: "groovy", name: "Groovy")
        l.aliases = ["gradle", "jenkinsfile"]
        l.extensions = ["groovy", "gradle", "gvy", "gy", "gsh"]
        l.fileNames = ["Jenkinsfile"]
        l.keywords = w("abstract as assert break case catch class const continue def default do else enum extends final finally for goto if implements import in instanceof interface new package private protected public return static super switch synchronized this throw throws trait transient try var void volatile while")
        l.literals = w("true false null")
        l.lineComments = ["//"]
        l.blockComments = cComments
        l.strings = [StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""), StringRule("'")]
        l.atAttributes = true
        l.capitalizedTypes = true
        return l
    }()

    public static let plainText: Language = {
        var l = Language(id: "text", name: "Plain Text")
        l.aliases = ["txt", "plain", "plaintext", "text", "log"]
        l.extensions = ["txt", "text", "log", "out"]
        l.mode = .plain
        return l
    }()
}
