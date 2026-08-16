import metaphor

/// 影絵の役者ひとりの姿勢。**自作型を `Interpolatable` に準拠させる**ための型で、
/// 検査（`I7.customType`）と舞台の両方が同じものを使う。
///
/// `Tween<Silhouette>` にすると「立ち位置・傾き・扇の開き」がひとつの予約で同時に動く。
/// 4 本の `Tween<Float>` に分けるのと違い、途中で足並みが崩れない。
struct Silhouette: Interpolatable, Equatable {
    /// 舞台上の立ち位置（ピクセル）
    var x: Float
    var y: Float
    /// 上体の傾き（ラジアン）。お辞儀がこれ
    var lean: Float
    /// 扇の開き 0…1
    var open: Float

    static func interpolate(from: Silhouette, to: Silhouette, t: Float) -> Silhouette {
        Silhouette(
            x: from.x + (to.x - from.x) * t,
            y: from.y + (to.y - from.y) * t,
            lean: from.lean + (to.lean - from.lean) * t,
            open: from.open + (to.open - from.open) * t
        )
    }
}
