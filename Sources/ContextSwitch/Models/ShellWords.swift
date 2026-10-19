import Foundation

/// Splits a command line into arguments the way a shell would — enough of
/// it for pasting a command from Terminal or a README: whitespace between
/// words, '…' and "…" quoting, backslash escapes and `\` line breaks. No
/// variables, globs or pipes.
enum ShellWords {
    /// nil if a quote is left open.
    static func split(_ text: String) -> [String]? {
        // Typed quotes in a text view often become smart quotes.
        let text = text
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        var words: [String] = []
        var word = ""
        var inWord = false  // so "" still makes an (empty) argument
        var quote: Character?
        var chars = text.makeIterator()
        while let c = chars.next() {
            switch quote {
            case "'":
                if c == "'" { quote = nil } else { word.append(c) }
            case "\"":
                if c == "\"" {
                    quote = nil
                } else if c == "\\" {
                    guard let next = chars.next() else { return nil }
                    if next.isNewline { continue }
                    if !"\"\\$`".contains(next) { word.append(c) }
                    word.append(next)
                } else {
                    word.append(c)
                }
            default:
                if c == "'" || c == "\"" {
                    quote = c
                    inWord = true
                } else if c == "\\" {
                    // A trailing backslash (end of a copied line) is dropped.
                    guard let next = chars.next() else { break }
                    if next.isNewline { continue }
                    word.append(next)
                    inWord = true
                } else if c.isWhitespace {
                    if inWord { words.append(word) }
                    word = ""
                    inWord = false
                } else {
                    word.append(c)
                    inWord = true
                }
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }

    /// Splits `text` into arguments for `program`, leaving out the program
    /// itself if the text starts with it — as a whole pasted command does.
    static func arguments(fromCommandLine text: String, program: URL?) -> [String]? {
        guard var words = split(text) else { return nil }
        if let program, let first = words.first, !first.hasPrefix("-"),
           first == program.lastPathComponent
            || URL(fileURLWithPath: (first as NSString).expandingTildeInPath).standardizedFileURL.path
               == program.standardizedFileURL.path {
            words.removeFirst()
        }
        return words
    }

    /// The reverse of `split`, quoting only where needed.
    static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    private static let plain = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    private static func quote(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        var quoted = "\""
        for c in word {
            if "\"\\$`".contains(c) { quoted.append("\\") }
            quoted.append(c)
        }
        return quoted + "\""
    }
}
