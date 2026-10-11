import AppKit
import SwiftUI

/// NIHO の配色。kamakura.niho.life と NIHO の小石マークの 6 色に合わせる。
///
/// 画面は白地にし、文字は焦げ茶寄り、主操作と選択は緑にする。色は意味と焦点に
/// だけ使い、面を塗りつぶさない。エラーにはブランド色を使わない。文字に使う色は
/// 白地で 4.5:1 以上になる濃さにしてある。
enum NihoPalette {
    // MARK: 面

    /// 窓・上部バー・編集パネル。
    static let canvas = Color.white
    /// 案内・カードなど、白地の上で一段だけ分ける面。
    static let surface = Color(nihoHex: 0xFAF7F2)
    /// PDF の後ろ。白いページの縁が見えるよう、白に近い生成りにする。
    static let pdfStage = Color(nihoHex: 0xF2EEE7)
    static let pdfStageNSColor = NSColor(srgbRed: 0xF2 / 255, green: 0xEE / 255, blue: 0xE7 / 255, alpha: 1)
    /// 区切り線。
    static let line = Color(nihoHex: 0x5D4335, opacity: 0.14)

    // MARK: 文字

    static let ink = Color(nihoHex: 0x333333)
    /// 見出し（焦げ茶）。
    static let heading = Color(nihoHex: 0x5D4335)
    /// 補足の文字。
    static let muted = Color(nihoHex: 0x76665C)

    // MARK: 焦点・意味

    /// 主操作・選択・入力できる状態。
    static let green = Color(nihoHex: 0x4D724F)
    /// エラー。
    static let danger = Color(nihoHex: 0xB8443A)
    /// PDF 上で選んだ文字の目印（珊瑚色）。
    static let selectionNSColor = NSColor(srgbRed: 0xF0 / 255, green: 0x9B / 255, blue: 0x84 / 255, alpha: 0.4)

    // MARK: 淡い面

    static let creamTint = Color(nihoHex: 0xF5EFE6)
    static let sageTint = Color(nihoHex: 0xEFF5E5)
}

extension Color {
    init(nihoHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// NIHO の区切り線（system の Divider を茶色の細線に置き換える）。
struct NihoDivider: View {
    var body: some View {
        Divider().overlay(NihoPalette.line)
    }
}
