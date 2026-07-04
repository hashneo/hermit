import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - SyntaxHighlighter
//
// Lightweight regex-based tokenizer for common languages found in Hermit RFCs.
// Produces an NSAttributedString with token-coloured text using a fixed palette
// that works on both macOS and iOS.
//
// Supported languages (matched case-insensitively on the fence label):
//   go, swift, kotlin, java, javascript, typescript, js, ts,
//   python, py, ruby, rb, rust,
//   yaml, yml, json, toml, hcl, tf,
//   bash, sh, shell, zsh, fish,
//   sql, xml, html, css,
//   dockerfile, makefile
//
// Falls back to plain monospaced text for unknown / empty language labels.

enum SyntaxHighlighter {

    // MARK: Public

    /// Returns a syntax-highlighted NSAttributedString for `code` written in `language`.
    /// Falls back to plain monospaced text if the language is unrecognised.
    static func highlight(code: String, language: String) -> NSAttributedString {
        let lang = language.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lang.isEmpty, let rules = grammar(for: lang) else {
            return plain(code)
        }
        return tokenize(code, rules: rules)
    }

    // MARK: Platform font / colour helpers

#if os(macOS)
    static func monoFont(size: CGFloat = NSFont.systemFontSize - 1) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(red: r, green: g, blue: b, alpha: 1)
    }
    private static var defaultForeground: NSColor { .labelColor }
#else
    static func monoFont(size: CGFloat = UIFont.systemFontSize - 1) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    private static var defaultForeground: UIColor { .label }
#endif

    // MARK: Token palette

    // A simple palette readable on the light-green background.
    private enum Palette {
        static var keyword:    AnyObject { color(0.13, 0.13, 0.80) }  // blue
        static var string:     AnyObject { color(0.60, 0.10, 0.10) }  // dark red
        static var comment:    AnyObject { color(0.40, 0.55, 0.40) }  // muted green
        static var number:     AnyObject { color(0.10, 0.40, 0.60) }  // teal
        static var type_:      AnyObject { color(0.45, 0.10, 0.55) }  // purple
        static var builtin:    AnyObject { color(0.00, 0.35, 0.55) }  // dark teal
        static var property:   AnyObject { color(0.20, 0.20, 0.20) }  // near-black
        static var plain:      AnyObject { defaultForeground }

        // Convenience so the compiler accepts both NS/UIColor in the same call
        private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> AnyObject {
            SyntaxHighlighter.color(r, g, b)
        }
        private static var defaultForeground: AnyObject {
            SyntaxHighlighter.defaultForeground
        }
    }

    // MARK: Token rule

    private struct Rule {
        let pattern: NSRegularExpression
        let color: AnyObject
    }

    private static func rule(_ pattern: String, _ color: AnyObject) -> Rule? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        return Rule(pattern: re, color: color)
    }

    // MARK: Tokenizer

    private static func plain(_ code: String) -> NSAttributedString {
        let font = monoFont()
        return NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: defaultForeground
        ])
    }

    private static func tokenize(_ code: String, rules: [Rule]) -> NSAttributedString {
        let font = monoFont()
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: defaultForeground
        ]
        let result = NSMutableAttributedString(string: code, attributes: base)
        let nsCode = code as NSString
        let full = NSRange(location: 0, length: nsCode.length)

        // Apply rules in order; later rules don't overwrite earlier ones (first match wins).
        // We track a "painted" set by checking existing foreground colour.
        // Simpler approach: apply all rules in order (last wins), then re-apply comment/string
        // on top since those take priority over keywords inside them.
        // Two-pass: (1) keywords/numbers/types, (2) strings, (3) comments on top.
        for rule in rules {
            rule.pattern.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let r = match?.range else { return }
                result.addAttribute(.foregroundColor, value: rule.color, range: r)
            }
        }

        return result
    }

    // MARK: Grammars

    private static func grammar(for lang: String) -> [Rule]? {
        switch lang {
        case "go":            return goRules
        case "swift":         return swiftRules
        case "kotlin":        return kotlinRules
        case "java":          return javaRules
        case "javascript","js","typescript","ts": return jsRules
        case "python","py":   return pythonRules
        case "ruby","rb":     return rubyRules
        case "rust":          return rustRules
        case "yaml","yml":    return yamlRules
        case "json":          return jsonRules
        case "toml":          return tomlRules
        case "hcl","tf":      return hclRules
        case "bash","sh","shell","zsh","fish": return shellRules
        case "sql":           return sqlRules
        case "xml","html":    return xmlRules
        case "css":           return cssRules
        case "dockerfile":    return dockerfileRules
        case "makefile","make": return makefileRules
        default:              return nil
        }
    }

    // MARK: Rule sets
    // Rules are applied in order; later rules overwrite earlier ones.
    // Comments and strings are last so they always win.

    private static var goRules: [Rule] {
        let kw = #"\b(break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var)\b"#
        let builtin = #"\b(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)\b"#
        let types = #"\b(bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr|any)\b"#
        return [
            rule(#"\b\d+(\.\d+)?(e[+-]?\d+)?\b"#,     Palette.number),
            rule(types,                                  Palette.type_),
            rule(builtin,                                Palette.builtin),
            rule(kw,                                     Palette.keyword),
            rule(#"`[^`]*`"#,                            Palette.string),   // raw strings
            rule(#""(?:[^"\\]|\\.)*""#,                  Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,                  Palette.string),
            rule(#"//[^\n]*"#,                           Palette.comment),
            rule(#"/\*.*?\*/"#,                          Palette.comment),
        ].compactMap { $0 }
    }

    private static var swiftRules: [Rule] {
        let kw = #"\b(actor|any|as|associatedtype|async|await|break|case|catch|class|continue|default|defer|deinit|do|else|enum|extension|fallthrough|false|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|lazy|let|mutating|nil|nonmutating|open|operator|override|postfix|prefix|private|protocol|public|repeat|required|return|rethrows|self|set|some|static|struct|subscript|super|switch|throw|throws|true|try|type|typealias|unowned|var|weak|where|while|willSet|didSet)\b"#
        let types = #"\b[A-Z][A-Za-z0-9_]*\b"#
        return [
            rule(#"\b\d+(\.\d+)?\b"#,                   Palette.number),
            rule(types,                                   Palette.type_),
            rule(kw,                                      Palette.keyword),
            rule("##\"[^\"]*\"##",                         Palette.string),   // raw strings (Swift #"..."#)
            rule(#""""[\s\S]*?""""#,                      Palette.string),   // multiline
            rule(#""(?:[^"\\]|\\.)*""#,                   Palette.string),
            rule(#"//[^\n]*"#,                            Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,                      Palette.comment),
        ].compactMap { $0 }
    }

    private static var kotlinRules: [Rule] {
        let kw = #"\b(abstract|actual|annotation|as|break|by|catch|class|companion|const|constructor|continue|crossinline|data|delegate|do|dynamic|else|enum|expect|external|false|field|file|final|finally|for|fun|get|if|import|in|infix|init|inline|inner|interface|internal|is|it|lateinit|noinline|null|object|open|operator|out|override|package|param|private|property|protected|public|receiver|reified|return|sealed|set|setparam|super|suspend|tailrec|this|throw|true|try|typealias|typeof|val|value|var|vararg|when|where|while)\b"#
        return goRules.dropLast(4) + [
            rule(kw,                         Palette.keyword),
            rule(#""(?:[^"\\]|\\.)*""#,       Palette.string),
            rule(#"//[^\n]*"#,               Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,          Palette.comment),
        ].compactMap { $0 }
    }

    private static var javaRules: [Rule] {
        let kw = #"\b(abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|null|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|true|try|void|volatile|while)\b"#
        return [
            rule(#"\b\d+(\.\d+)?(L|f|d)?\b"#, Palette.number),
            rule(#"\b[A-Z][A-Za-z0-9_]*\b"#,   Palette.type_),
            rule(kw,                             Palette.keyword),
            rule(#""(?:[^"\\]|\\.)*""#,           Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,           Palette.string),
            rule(#"//[^\n]*"#,                   Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,              Palette.comment),
        ].compactMap { $0 }
    }

    private static var jsRules: [Rule] {
        let kw = #"\b(async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|false|try|typeof|undefined|var|void|while|with|yield)\b"#
        return [
            rule(#"\b\d+(\.\d+)?\b"#,           Palette.number),
            rule(#"\b[A-Z][A-Za-z0-9_]*\b"#,    Palette.type_),
            rule(kw,                              Palette.keyword),
            rule(#"`(?:[^`\\]|\\.)*`"#,           Palette.string),   // template literals
            rule(#""(?:[^"\\]|\\.)*""#,            Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,            Palette.string),
            rule(#"//[^\n]*"#,                    Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,               Palette.comment),
        ].compactMap { $0 }
    }

    private static var pythonRules: [Rule] {
        let kw = #"\b(and|as|assert|async|await|break|class|continue|def|del|elif|else|except|exec|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|print|raise|return|True|try|while|with|yield)\b"#
        return [
            rule(#"\b\d+(\.\d+)?\b"#,               Palette.number),
            rule(#"\b[A-Z][A-Za-z0-9_]*\b"#,        Palette.type_),
            rule(kw,                                  Palette.keyword),
            rule(#""""[\s\S]*?""""#,                  Palette.string),
            rule(#"'''[\s\S]*?'''"#,                  Palette.string),
            rule(#""(?:[^"\\]|\\.)*""#,               Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,               Palette.string),
            rule(#"#[^\n]*"#,                         Palette.comment),
        ].compactMap { $0 }
    }

    private static var rubyRules: [Rule] {
        let kw = #"\b(alias|and|begin|break|case|class|def|defined\?|do|else|elsif|end|ensure|false|for|if|in|module|next|nil|not|or|raise|redo|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield)\b"#
        return [
            rule(#"\b\d+(\.\d+)?\b"#,   Palette.number),
            rule(kw,                      Palette.keyword),
            rule("\"(?:[^\"\\\\ #]|\\\\.)*\"",  Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,  Palette.string),
            rule(#"#[^\n]*"#,            Palette.comment),
            rule(#"=begin[\s\S]*?=end"#, Palette.comment),
        ].compactMap { $0 }
    }

    private static var rustRules: [Rule] {
        let kw = #"\b(as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|union|unsafe|use|where|while)\b"#
        return [
            rule(#"\b\d+(\.\d+)?(u8|u16|u32|u64|i8|i16|i32|i64|f32|f64|usize|isize)?\b"#, Palette.number),
            rule(#"\b[A-Z][A-Za-z0-9_]*\b"#, Palette.type_),
            rule(kw,                           Palette.keyword),
            rule("r##\"[\\s\\S]*?\"##r",                  Palette.string),
            rule(#""(?:[^"\\]|\\.)*""#,         Palette.string),
            rule(#"'(?:[^'\\]|\\.)*'"#,         Palette.string),
            rule(#"//[^\n]*"#,                 Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,            Palette.comment),
        ].compactMap { $0 }
    }

    private static var yamlRules: [Rule] {
        return [
            rule(#"#[^\n]*"#,                              Palette.comment),
            rule(#"^[ \t]*[a-zA-Z_][\w\-]*(?=\s*:)"#,     Palette.keyword),   // keys
            rule(#":\s*[|>]"#,                             Palette.builtin),
            rule(#"'[^']*'"#,                              Palette.string),
            rule(#""(?:[^"\\]|\\.)*""#,                    Palette.string),
            rule(#"\b(true|false|null|yes|no)\b"#,         Palette.number),
            rule(#"\b\d+(\.\d+)?\b"#,                     Palette.number),
        ].compactMap { $0 }
    }

    private static var jsonRules: [Rule] {
        return [
            rule(#""(?:[^"\\]|\\.)*"\s*:"#,    Palette.keyword),   // keys
            rule(#""(?:[^"\\]|\\.)*""#,         Palette.string),
            rule(#"\b(true|false|null)\b"#,     Palette.builtin),
            rule(#"\b-?\d+(\.\d+)?(e[+-]?\d+)?\b"#, Palette.number),
        ].compactMap { $0 }
    }

    private static var tomlRules: [Rule] {
        return [
            rule(#"#[^\n]*"#,                        Palette.comment),
            rule(#"\[[^\]]+\]"#,                     Palette.type_),   // sections
            rule(#"^[a-zA-Z_][\w\-]*(?=\s*=)"#,     Palette.keyword), // keys
            rule(#""(?:[^"\\]|\\.)*""#,               Palette.string),
            rule(#"'[^']*'"#,                         Palette.string),
            rule(#"\b(true|false)\b"#,                Palette.builtin),
            rule(#"\b\d+(\.\d+)?\b"#,                Palette.number),
        ].compactMap { $0 }
    }

    private static var hclRules: [Rule] {
        let kw = #"\b(resource|data|variable|output|locals|module|provider|terraform|required_providers|backend|provisioner|lifecycle|dynamic|for_each|count|depends_on|source|version|true|false|null)\b"#
        return [
            rule(#"#[^\n]*"#,             Palette.comment),
            rule(#"//[^\n]*"#,            Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,       Palette.comment),
            rule(kw,                       Palette.keyword),
            rule(#""(?:[^"\\$]|\\.)*""#,   Palette.string),
            rule(#"\$\{[^}]*\}"#,          Palette.builtin),  // interpolations
            rule(#"\b\d+(\.\d+)?\b"#,     Palette.number),
        ].compactMap { $0 }
    }

    private static var shellRules: [Rule] {
        let kw = #"\b(if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|exit|export|local|readonly|declare|unset|shift|set|source|alias|break|continue|trap|exec)\b"#
        return [
            rule(#"#[^\n]*"#,              Palette.comment),
            rule(kw,                        Palette.keyword),
            rule(#"\$\{?[A-Za-z_]\w*\}?"#, Palette.builtin),  // variables
            rule(#""(?:[^"\\$]|\\.)*""#,    Palette.string),
            rule(#"'[^']*'"#,               Palette.string),
            rule(#"\b\d+\b"#,              Palette.number),
        ].compactMap { $0 }
    }

    private static var sqlRules: [Rule] {
        let kw = #"\b(ADD|ALL|ALTER|AND|AS|ASC|BETWEEN|BY|CASE|COLUMN|CONSTRAINT|CREATE|CROSS|DATABASE|DEFAULT|DELETE|DESC|DISTINCT|DROP|ELSE|END|EXCEPT|EXISTS|FROM|FULL|GROUP|HAVING|IN|INDEX|INNER|INSERT|INTERSECT|INTO|IS|JOIN|LEFT|LIKE|LIMIT|NOT|NULL|ON|OR|ORDER|OUTER|PRIMARY|RIGHT|SELECT|SET|TABLE|THEN|TOP|TRUNCATE|UNION|UNIQUE|UPDATE|VALUES|VIEW|WHEN|WHERE|WITH|add|all|alter|and|as|asc|between|by|case|column|constraint|create|cross|database|default|delete|desc|distinct|drop|else|end|except|exists|from|full|group|having|in|index|inner|insert|intersect|into|is|join|left|like|limit|not|null|on|or|order|outer|primary|right|select|set|table|then|top|truncate|union|unique|update|values|view|when|where|with)\b"#
        return [
            rule(#"--[^\n]*"#,             Palette.comment),
            rule(#"/\*[\s\S]*?\*/"#,        Palette.comment),
            rule(kw,                         Palette.keyword),
            rule(#"'(?:[^'\\]|\\.)*'"#,     Palette.string),
            rule(#"\b\d+(\.\d+)?\b"#,       Palette.number),
        ].compactMap { $0 }
    }

    private static var xmlRules: [Rule] {
        return [
            rule(#"<!--[\s\S]*?-->"#,           Palette.comment),
            rule(#"</?[a-zA-Z][a-zA-Z0-9_:.-]*"#, Palette.keyword),
            rule(#"[a-zA-Z_:][a-zA-Z0-9_:.-]*(?=\s*=)"#, Palette.builtin), // attributes
            rule(#""[^"]*""#,                    Palette.string),
            rule(#"'[^']*'"#,                    Palette.string),
            rule(#"&[a-zA-Z]+;"#,                Palette.number),
        ].compactMap { $0 }
    }

    private static var cssRules: [Rule] {
        return [
            rule(#"/\*[\s\S]*?\*/"#,          Palette.comment),
            rule(#"[.#]?[a-zA-Z][a-zA-Z0-9_-]*(?=\s*\{)"#, Palette.type_), // selectors
            rule(#"[a-zA-Z-]+(?=\s*:)"#,       Palette.keyword),            // properties
            rule(#":\s*[^;{]+"#,               Palette.string),             // values
            rule(#"#[0-9a-fA-F]{3,8}\b"#,      Palette.number),
            rule(#"\b\d+(\.\d+)?(px|em|rem|%|vh|vw|pt|cm|mm)?\b"#, Palette.number),
        ].compactMap { $0 }
    }

    private static var dockerfileRules: [Rule] {
        let kw = #"^(FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)"#
        return [
            rule(#"#[^\n]*"#,   Palette.comment),
            rule(kw,             Palette.keyword),
            rule(#""[^"]*""#,   Palette.string),
        ].compactMap { $0 }
    }

    private static var makefileRules: [Rule] {
        return [
            rule(#"#[^\n]*"#,                           Palette.comment),
            rule(#"^[a-zA-Z_][a-zA-Z0-9_.-]*(?=\s*:)"#, Palette.keyword), // targets
            rule(#"\$\(?[A-Za-z_]\w*\)?"#,              Palette.builtin),  // variables
            rule(#"\b(ifeq|ifneq|ifdef|ifndef|else|endif|include|define|endef|override|export|unexport)\b"#, Palette.type_),
        ].compactMap { $0 }
    }
}
