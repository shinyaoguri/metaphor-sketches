import Foundation
import metaphor

/// 一座（座組）。**1 公演ぶんの振付を `Tween` の束として持つ。**
///
/// 舞台に 2 つ並ぶ座組は、振付も刻み方もまったく同じで、**違いは 1 か所だけ**——
/// アンコールのときに `Tween` を `tweenManager` へ**登録し直すか**（`readmitsOnEncore`）。
///
/// `TweenManager.update` は完了した `Tween` を配列から外す。外れた `Tween` に `start()` を
/// 掛けても、もう誰も `update` を呼ばない。`Tween.update(_:)` は `internal` なので
/// 利用者が手で進めることもできない。だから「登録し直す」の一手が要る——
/// というのがこの舞台の主題で、対照実験そのものになっている。
@MainActor
final class Troupe {

    // MARK: - 座組の性格

    let title: String
    let note: String
    /// アンコールで `tweenManager.add` をやり直すか。**ここだけが 2 座の違い。**
    let readmitsOnEncore: Bool

    /// 既定の `tweenManager`。`SketchContext` が毎フレーム `update` を叩く。
    /// `Sketch` 側に素の別名が無いので `context.tweenManager` を持ち回る。
    private let manager: TweenManager

    // MARK: - 振付（= 予約された動き）

    /// 幕。開きが 0…1。**幕だけは両座とも毎回登録し直す**（座長が手で引く体）。
    /// そうしないと壊れた側の舞台が閉じたままになり、肝心の「誰も出てこない舞台」が見えない。
    private(set) var curtainUp: Tween<Float>
    private(set) var curtainDown: Tween<Float>

    /// 役者の出。袖 → 立ち位置。`delay` が出のきっかけで、`easeOutBack` で行き過ぎて収まる。
    private(set) var entrances: [Tween<Silhouette>]
    /// 所作。`yoyo().repeatCount(0)` の無限往復。会釈の前に `cancel()` で畳む。
    private(set) var flourishes: [Tween<Float>]
    /// 会釈。立ち位置 → 中央寄りへ。`from` は立ち位置と同じなので、出が終わる前でも繋がる。
    private(set) var bows: [Tween<Silhouette>]

    /// 袖の位置（壊れた座組はここへ巻き戻って凍る）。
    private(set) var wings: [Silhouette]

    // MARK: - 進行

    private(set) var performance = 1
    private(set) var elapsed: Float = 0
    private var flourishesCancelled = false

    /// 台本の刻み（秒）。1 公演 = 約 17.2 秒。
    static let cancelFlourishAt: Float = 12.5
    static let performanceEndsAt: Float = 17.2

    // MARK: - 組み立て

    init(title: String, note: String, readmitsOnEncore: Bool,
         manager: TweenManager, marks: [Silhouette], wings: [Silhouette]) {
        self.title = title
        self.note = note
        self.readmitsOnEncore = readmitsOnEncore
        self.manager = manager
        self.wings = wings

        curtainUp = Tween(from: 0, to: 1, duration: 2.2, easing: easeInOutCubic).delay(0.3)
        curtainDown = Tween(from: 1, to: 0, duration: 2.0, easing: easeInOutCubic).delay(14.8)

        entrances = zip(wings, marks).enumerated().map { i, pair in
            // easeOutBack は t<1 で 1 を越える。役者が立ち位置を行き過ぎて戻る見得になり、
            // 同時に「Interpolatable は t を 0…1 にクランプしない」（I6）が絵に出る。
            Tween(from: pair.0, to: pair.1, duration: 2.2, easing: easeOutBack)
                .delay(2.6 + Float(i) * 0.6)
        }

        flourishes = marks.indices.map { i in
            Tween(from: Float(0), to: Float(1), duration: 1.5 + Float(i) * 0.2, easing: easeInOutSine)
                .delay(5.2 + Float(i) * 0.6)
                .yoyo()
                .repeatCount(0)  // 無限。cancel() 以外で止まらない
        }

        bows = marks.enumerated().map { i, mark in
            var center = mark
            center.x = marks.map(\.x).reduce(0, +) / Float(marks.count)
            center.y = mark.y - 6
            center.lean = 0.42   // 深い会釈
            center.open = 0
            return Tween(from: mark, to: center, duration: 1.4, easing: easeInOutCubic)
                .delay(12.6 + Float(i) * 0.25)
        }
    }

    // MARK: - 開演とアンコール

    /// 初回の開演。全ての `Tween` を登録して回し始める。
    func openHouse() {
        admitAll()
        startAll()
        elapsed = 0
        flourishesCancelled = false
    }

    /// アンコール。**ここが 2 座の分かれ道。**
    ///
    /// どちらも `reset()` → `start()` という doc から素直に読める書き方をする。
    /// 違うのは、その前に `tweenManager` へ入れ直すかどうかだけ。
    func encore() {
        performance += 1
        elapsed = 0
        flourishesCancelled = false

        // 幕は両座とも引き直す（そうしないと舞台が見えない）
        manager.add(curtainUp)
        manager.add(curtainDown)

        if readmitsOnEncore {
            admitActors()
        }

        resetAll()
        startAll()
    }

    private func admitAll() {
        manager.add(curtainUp)
        manager.add(curtainDown)
        admitActors()
    }

    private func admitActors() {
        for t in entrances { manager.add(t) }
        for t in flourishes { manager.add(t) }
        for t in bows { manager.add(t) }
    }

    private func resetAll() {
        curtainUp.reset(); curtainDown.reset()
        for t in entrances { t.reset() }
        for t in flourishes { t.reset() }
        for t in bows { t.reset() }
    }

    private func startAll() {
        curtainUp.start(); curtainDown.start()
        for t in entrances { t.start() }
        for t in flourishes { t.start() }
        for t in bows { t.start() }
    }

    // MARK: - 毎フレーム

    /// 台本の進行だけを見る。`Tween` の更新はフレームループ（`SketchContext.beginFrame`）の仕事。
    func advance(_ dt: Float) {
        elapsed += dt
        if !flourishesCancelled && elapsed >= Self.cancelFlourishAt {
            flourishesCancelled = true
            // 無限リピートを畳む唯一の手段。onComplete は呼ばれない。
            for t in flourishes { t.cancel() }
        }
    }

    var performanceFinished: Bool { elapsed >= Self.performanceEndsAt }

    // MARK: - 舞台に見せる値

    /// 幕の開き 0…1。開く側と閉じる側の小さいほうを採ると、
    /// 待機中（値が `from` のまま）も含めて 1 本の連続した動きになる。
    var curtainOpen: Float { min(curtainUp.value, curtainDown.value) }

    /// 役者 i の、いま描くべき姿勢。
    func pose(_ i: Int) -> Silhouette {
        let entrance = entrances[i]
        // 出が終わっていれば会釈側の値（`from` が立ち位置なので、待機中でも同じ姿勢）
        var s = entrance.isComplete ? bows[i].value : entrance.value
        let f = flourishes[i].value
        s.lean += f * 0.30
        s.open = max(s.open, f)
        return s
    }

    /// 進行表に出す 1 行ぶんの状態。
    ///
    /// 公開されているのは `isActive` と `isComplete` だけ。`.delaying` はどちらも false を返すので
    /// **「袖で待っている」と「出番が無い」を外から区別できない**（`T2b`）。
    /// だから待機は `—` としか書けない。
    func state(of tw: some AnyTweenState) -> String {
        if tw.isComplete { return "DONE" }
        if tw.isActive { return "RUN " }
        return "—   "
    }
}

/// 進行表が読みたいのは `isActive` / `isComplete` だけ。型引数を消して 1 行として扱う。
@MainActor
protocol AnyTweenState {
    var isActive: Bool { get }
    var isComplete: Bool { get }
}

extension Tween: AnyTweenState {}
