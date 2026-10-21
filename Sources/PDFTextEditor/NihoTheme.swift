import AppKit
import SwiftUI

/// PDF editor の配色。白基調で、面は白とごく淡い灰の 2 段だけにする。
///
/// 文字は墨（#1C1C1A）、補足は灰。主ボタンは若草（#B2D67C）の塗りに墨の文字を載せ、
/// 選択・フォーカスの線も若草系にする。文字や `.tint` に使う緑は白地で読める濃い緑に
/// 分けてある。エラーにはブランド色を使わない。
enum NihoPalette {
    // MARK: 面

    /// 窓・上のバー・右のパネル。
    static let canvas = Color.white
    /// 白地の上で一段だけ分ける面。
    static let surface = Color(nihoHex: 0xF7F7F4)
    /// PDF の後ろ。白いページの縁が見えるよう、白に近い灰にする。
    static let pdfStage = Color(nihoHex: 0xF7F7F4)
    static let pdfStageNSColor = NSColor(srgbRed: 0xF7 / 255, green: 0xF7 / 255, blue: 0xF4 / 255, alpha: 1)
    /// 押せるものの hover・選択中の面。
    static let bg3 = Color(nihoHex: 0xEFEFEB)
    /// 区切り線。
    static let line = Color(nihoHex: 0xE7E7E2)
    /// 入力欄・白地のボタンの枠。
    static let line2 = Color(nihoHex: 0xD4D4CF)

    // MARK: 文字

    static let ink = Color(nihoHex: 0x1C1C1A)
    /// 一段弱い文字（アイコン・ghost のボタン）。
    static let ink2 = Color(nihoHex: 0x55554F)
    /// 見出し。
    static let heading = Color(nihoHex: 0x1C1C1A)
    /// 補足の文字。
    static let muted = Color(nihoHex: 0x8A8A84)

    // MARK: 焦点・意味

    /// 文字・`.tint` 用の濃い緑。
    static let green = Color(nihoHex: 0x3F7A3E)
    /// 主ボタンの塗り（若草）。文字は ink を載せる。
    static let primaryFill = Color(nihoHex: 0xB2D67C)
    /// 選択枠・フォーカス枠・PDF 上の線。
    static let greenLine = Color(nihoHex: 0x8FB55A)
    /// エラー。
    static let danger = Color(nihoHex: 0xC2472E)
    /// PDF 上で選んだ文字の目印（若草の半透明）。
    static let selectionNSColor = NSColor(srgbRed: 0xB2 / 255, green: 0xD6 / 255, blue: 0x7C / 255, alpha: 0.5)

    // MARK: 淡い面

    static let creamTint = Color(nihoHex: 0xEFEFEB)
    static let sageTint = Color(nihoHex: 0xEDF5E1)
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

/// 区切り線（system の Divider を淡い灰の細線に置き換える）。
struct NihoDivider: View {
    var body: some View {
        Divider().overlay(NihoPalette.line)
    }
}
