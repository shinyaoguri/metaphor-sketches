import metaphor

// 組版機。
//
// **この型は metaphor の公開の計量 API しか知らない。** 語の幅は渡された `measure` で測り、
// 行の高さは渡された `lineHeight` に従う。グリフの advance もアトラスの中身も見ない
// (見てしまうと「測り値と描画が一致するか」という問いが自明に成立してしまう)。
//
// 両端揃えは計量に全面的に依存する営みなので、測り値が実際の描画と食い違えば
// 右端が揃わない。**揃わなさがそのまま計量の誤差**になる、というのがこの作品の仕掛け。

/// 組み上がった 1 行。
struct SetLine {
    let words: [String]
    /// 行頭の x。
    let x: Float
    /// ベースラインの y。
    let baseline: Float
    /// 実際に使う語間 (px)。両端揃えの行では自然幅から広げてある。
    let gap: Float
    /// 語幅の合計 (`measure` の返り値の和。語間は含まない)。
    let sumWords: Float
    /// 段の幅。
    let columnWidth: Float
    /// 両端揃えを適用した行か (段落の最終行は左揃えのまま残す)。
    let justified: Bool

    /// 測り値どおりに刷られたなら、最後の語の右端はここに来るはず。
    ///
    /// 両端揃えの行では定義上ちょうど段の右端。揃えていない行は語幅と語間の素の和。
    var expectedRight: Float {
        justified
            ? x + columnWidth
            : x + sumWords + gap * Float(max(0, words.count - 1))
    }

    /// 語ごとの (文字列, 行頭からの x)。刷るときも判定するときもこれを使う。
    func placed(_ measure: (String) -> Float) -> [(word: String, x: Float)] {
        var out: [(word: String, x: Float)] = []
        var cursor = x
        for w in words {
            out.append((word: w, x: cursor))
            cursor += measure(w) + gap
        }
        return out
    }
}

/// 語を並べて段に組む。
struct Compositor {
    /// 語の幅を測る唯一の口。`textWidth(_:)` をそのまま渡す。
    let measure: (String) -> Float
    /// 行送り。`textAscent() + textDescent()` から呼び出し側が作る。
    let lineHeight: Float
    let columnWidth: Float

    /// 語間の自然幅。
    ///
    /// `measure(" ")` を直接使わないのは、幅の実装が**光学バウンズ**
    /// (`CTLineGetBoundsWithOptions(.useOpticalBounds)`) だと両端の空白が落ち、
    /// 空白 1 文字の幅として 0 が返りうるため。差分で取れば実装が何を返そうと語間は得られる。
    /// **`measure(" ")` が使えるかどうかは G2 が別途照合する** — ここで避けたことが
    /// 検査から漏れないように。
    var naturalSpace: Float {
        max(1, measure("n n") - measure("nn"))
    }

    /// 貪欲に行分割して段に組む。
    ///
    /// - Parameters:
    ///   - words: 原稿の語。
    ///   - originX: 段の左端。
    ///   - firstBaseline: 1 行目のベースライン。
    ///   - maxLines: 段に入る行数。超えた分は `rest` に返す。
    ///   - ragged: true なら両端揃えをせず右を揃えないまま残す (欄外の註釈用)。
    /// - Returns: 組み上がった行と、収まらなかった残りの語。
    func set(_ words: [String], originX: Float, firstBaseline: Float,
             maxLines: Int, ragged: Bool = false) -> (lines: [SetLine], rest: [String]) {
        let space = naturalSpace
        var lines: [SetLine] = []
        var i = 0
        var baseline = firstBaseline

        while i < words.count && lines.count < maxLines {
            // 1. この行に入るだけ語を詰める。
            //    1 語で段幅を超える場合でも必ず 1 語は取る (取らないと i が進まず無限ループ)。
            var take = 0
            var natural: Float = 0
            while i + take < words.count {
                let w = measure(words[i + take])
                let next = natural + w + (take > 0 ? space : 0)
                if take > 0 && next > columnWidth { break }
                natural = next
                take += 1
            }

            let slice = Array(words[i..<(i + take)])
            let sumWords = natural - space * Float(max(0, take - 1))
            let isLastLine = (i + take >= words.count) || (lines.count == maxLines - 1)
            let justified = !ragged && !isLastLine && take >= 2

            // 2. 語間を配分する。段落の最終行は伸ばさない (組版の作法)。
            let gap = justified
                ? (columnWidth - sumWords) / Float(take - 1)
                : space

            lines.append(SetLine(
                words: slice, x: originX, baseline: baseline, gap: gap,
                sumWords: sumWords, columnWidth: columnWidth, justified: justified
            ))

            i += take
            baseline += lineHeight
        }

        return (lines, Array(words[min(i, words.count)...]))
    }
}
