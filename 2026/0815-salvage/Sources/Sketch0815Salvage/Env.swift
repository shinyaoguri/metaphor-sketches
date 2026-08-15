import Foundation

/// 環境変数の読み取り（1 本目 `0815-strata` から流用）。
///
/// 常設・無人稼働・ソークの都合で「起動時に決めて途中で変えない」設定は
/// すべてここを通す。実行時に変えたいものは `@Param` 側で持つ。
enum Env {
    static func string(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func bool(_ name: String) -> Bool {
        guard let value = string(name)?.lowercased() else { return false }
        return value != "0" && value != "false" && value != "no"
    }

    static func int(_ name: String, default fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let value = string(name).flatMap(Int.init) else { return fallback }
        return Swift.min(Swift.max(value, lo), hi)
    }

    static func float(_ name: String, default fallback: Float, min lo: Float, max hi: Float)
        -> Float
    {
        guard let value = string(name).flatMap(Float.init) else { return fallback }
        return Swift.min(Swift.max(value, lo), hi)
    }

    /// Syphon 名。`SALVAGE_SYPHON=1` なら既定名、文字列ならその名前。
    static func syphonName() -> String? {
        if let injected = string("METAPHOR_SYPHON_NAME") { return injected }
        guard let value = string("SALVAGE_SYPHON") else { return nil }
        let lowered = value.lowercased()
        if lowered == "0" || lowered == "false" || lowered == "no" { return nil }
        if lowered == "1" || lowered == "true" || lowered == "yes" { return "0815-salvage" }
        return value
    }
}
