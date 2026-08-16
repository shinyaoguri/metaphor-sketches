import metaphor

// 組む原稿。
//
// 固定の文字列にしてある (乱数も時計も混ぜない)。同じ原稿を同じ幅で組めば同じ紙面になり、
// 読み戻しの判定が実行のたびに同じ数値を出す — 検査の決定論性はここから来ている。
//
// 内容は「この紙面が何を確かめているか」そのもの。ゲラは本文を読むためのものなので、
// 校正記号の意味が本文から読み取れるようにしてある。

enum Copy {

    /// 面 1 の本文。両端揃えで 2 段に組む。
    ///
    /// 語の長さがばらけるよう、短い語と長い語を意図的に混ぜてある
    /// (すべて同じ長さだと語間の配分が均一になり、累積誤差が見えにくい)。
    static let body = """
    A galley proof exists to be wrong in public. \
    It is pulled before the page is committed, so that every \
    misfit can be marked in red while marking is still cheap. \
    This page is set by a compositor that knows nothing about \
    glyphs. It asks textWidth how wide a word will be, it asks \
    textAscent and textDescent how tall a line will stand, and \
    it trusts both answers completely. Word spaces are then \
    distributed so that each line finishes exactly on the right \
    margin. If the answers are true, the right edge of this \
    column is a straight line. If the ruler used for measuring \
    differs from the ruler used for drawing, the edge frays, \
    and the fraying is measured here in pixels rather than \
    argued about. Nothing else on this page is decoration. \
    A ruler that rounds every answer upward is not a ruler; \
    it is an optimist. Ask it for one letter and it will hand \
    you a whole pixel more than the letter owns, and the debt \
    is invisible until you ask sixteen times and compare. \
    Ask it about a trailing space and it will tell you the \
    space is not there at all, which is true of its own bounds \
    and false of the line you are trying to set. The drawing \
    side, meanwhile, keeps its own accounts: it lays one glyph \
    beside the next without ever consulting the pair, so the \
    kerning that the measuring side carefully applied is \
    quietly discarded on the way to the page. Two honest \
    clerks, two ledgers, one column that will not close. \
    None of this is visible in a headline. It becomes visible \
    when a hundred small decisions are stacked in a straight \
    line and asked to end together, which is exactly what \
    justified setting is for, and exactly why it is used here. \
    The compositor that set this page has no eyes. It cannot \
    see that a line looks loose, or that a word has slipped \
    past the margin, because it never looks at the page at \
    all; it only asks questions and adds up answers. That is \
    the point. A reader who trusts the finished column is \
    trusting arithmetic performed on measurements taken in \
    advance, and the only honest way to audit that trust is to \
    print the column and then measure the print. So the page \
    is read back, pixel by pixel, and the two accounts are \
    laid beside each other. Where they agree, nothing is \
    written. Where they disagree, the disagreement is drawn \
    in red at the exact place it occurred, together with the \
    number of pixels involved, because a correction without a \
    number is an opinion. Proofreading marks were invented for \
    the same reason: to say precisely where and precisely what, \
    in a language narrow enough that two people who have never \
    met can agree on what must change. Everything on this sheet \
    is written in that spirit. If the margins are clean, the \
    measuring was sound. If they are not, the marks say by how \
    much, and the argument is over before it begins.
    """

    /// 面 2 の見出し。中央揃えの基準がどこかを見るので、左右非対称な字面にしてある。
    static let headings = [
        "Measure",
        "Twice, Draw",
        "Once",
    ]

    /// 面 3 の格子に載せる行。下降部 (g, p, y) と上昇部 (h, l, k) を必ず含める
    /// — ベースラインの位置を ink の上端・下端から逆算するため。
    static let gridLines = [
        "Hamburgefonstiv",
        "typography, alight",
        "Quick jog by pixel",
    ]

    /// 面 4 の号数見本。1 語だけを大きさを変えて刷り、右端で揃える。
    static let specimen = "Rgh"

    /// 面 5 の端物。**退化した入力**を並べる。
    ///
    /// - 見出し: 欄外に出す説明
    /// - 値: 実際に `text()` へ渡す文字列
    static let oddments: [(label: String, value: String)] = [
        ("空文字列", ""),
        ("空白のみ", "   "),
        ("前後に空白", "  Rgh  "),
        ("改行を含む", "Rg\nhs"),
        ("左に食い込む字", "jjj"),
        ("advance より広い字", "WWW"),
    ]

    /// 語に割る。連続する空白は 1 つの区切りとして畳む。
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
