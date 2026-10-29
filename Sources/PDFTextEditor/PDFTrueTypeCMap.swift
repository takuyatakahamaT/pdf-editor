import CoreText
import Foundation

/// 埋め込み TrueType の `cmap` を直接読み、PDF の単純フォントで使われる
/// 1 byte 文字コードを GID に変換する。
///
/// PDF の `/ToUnicode` は「PDF文字コード → Unicode」を表す一方、CoreText の
/// Unicode 描画は埋め込み subset の cmap を別の意味で解釈することがある。その場合、
/// 正しい書体を選んでも別の漢字が描かれる。ここでは ToUnicode を逆引きして得た
/// PDF文字コードを cmap に通し、Unicode レイアウトを介さず元の GID を使う。
enum PDFTrueTypeCMap {
    private struct EncodingRecord {
        let platformID: Int
        let encodingID: Int
        let offset: Int

        var priority: Int {
            switch (platformID, encodingID) {
            case (3, 0): return 0 // Windows Symbol
            case (1, 0): return 1 // Macintosh Roman / subset code space
            default: return 2
            }
        }

        var usesPDFCodeSpaceDirectly: Bool {
            (platformID == 3 && encodingID == 0) || (platformID == 1 && encodingID == 0)
        }
    }

    static func glyphID(forCharacterCode code: Int, in font: CTFont) -> CGGlyph? {
        guard code >= 0,
              let table = CTFontCopyTable(
                font,
                CTFontTableTag(0x636D6170), // 'cmap'
                CTFontTableOptions(rawValue: 0)
              ) else { return nil }
        return glyphID(forCharacterCode: code, cmapData: table as Data)
    }

    static func glyphID(forCharacterCode code: Int, cmapData: Data) -> CGGlyph? {
        guard code >= 0,
              let tableCount = uint16(cmapData, at: 2) else { return nil }

        var records: [EncodingRecord] = []
        records.reserveCapacity(Int(tableCount))
        for index in 0..<Int(tableCount) {
            let base = 4 + index * 8
            guard let platform = uint16(cmapData, at: base),
                  let encoding = uint16(cmapData, at: base + 2),
                  let offset = uint32(cmapData, at: base + 4),
                  Int(offset) < cmapData.count else { continue }
            records.append(EncodingRecord(
                platformID: Int(platform),
                encodingID: Int(encoding),
                offset: Int(offset)
            ))
        }

        var visitedOffsets = Set<Int>()
        for record in records.filter(\.usesPDFCodeSpaceDirectly).sorted(by: { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.offset < rhs.offset : lhs.priority < rhs.priority
        }) where visitedOffsets.insert(record.offset).inserted {
            var candidateCodes = [code]
            if record.platformID == 3, record.encodingID == 0, code <= 0xFF {
                candidateCodes.append(code | 0xF000)
            }
            for candidate in candidateCodes {
                guard let glyph = glyphID(
                    forCharacterCode: candidate,
                    in: cmapData,
                    subtableOffset: record.offset
                ), glyph != 0 else { continue }
                return CGGlyph(glyph)
            }
        }
        return nil
    }

    private static func glyphID(
        forCharacterCode code: Int,
        in data: Data,
        subtableOffset offset: Int
    ) -> UInt16? {
        guard let format = uint16(data, at: offset) else { return nil }
        switch format {
        case 0:
            guard code <= 0xFF else { return nil }
            return uint8(data, at: offset + 6 + code).map(UInt16.init)

        case 4:
            guard code <= 0xFFFF,
                  let segCountX2 = uint16(data, at: offset + 6),
                  segCountX2 > 0, segCountX2.isMultiple(of: 2) else { return nil }
            let segmentCount = Int(segCountX2 / 2)
            let endCodes = offset + 14
            let startCodes = endCodes + segmentCount * 2 + 2
            let deltas = startCodes + segmentCount * 2
            let rangeOffsets = deltas + segmentCount * 2
            guard rangeOffsets + segmentCount * 2 <= data.count else { return nil }

            for index in 0..<segmentCount {
                guard let end = uint16(data, at: endCodes + index * 2),
                      let start = uint16(data, at: startCodes + index * 2) else { return nil }
                let value = UInt16(code)
                guard value >= start, value <= end else { continue }
                guard let deltaBits = uint16(data, at: deltas + index * 2),
                      let rangeOffset = uint16(data, at: rangeOffsets + index * 2) else { return nil }
                let delta = Int(Int16(bitPattern: deltaBits))
                if rangeOffset == 0 {
                    return UInt16(truncatingIfNeeded: Int(value) + delta)
                }
                let rangeOffsetAddress = rangeOffsets + index * 2
                let glyphAddress = rangeOffsetAddress
                    + Int(rangeOffset)
                    + 2 * (Int(value) - Int(start))
                guard let glyph = uint16(data, at: glyphAddress), glyph != 0 else { return nil }
                return UInt16(truncatingIfNeeded: Int(glyph) + delta)
            }
            return nil

        case 6:
            guard let firstCode = uint16(data, at: offset + 6),
                  let entryCount = uint16(data, at: offset + 8),
                  code >= Int(firstCode),
                  code < Int(firstCode) + Int(entryCount) else { return nil }
            return uint16(data, at: offset + 10 + (code - Int(firstCode)) * 2)

        case 10:
            guard let firstCode = uint32(data, at: offset + 12),
                  let entryCount = uint32(data, at: offset + 16),
                  UInt64(code) >= UInt64(firstCode),
                  UInt64(code) < UInt64(firstCode) + UInt64(entryCount) else { return nil }
            let index = UInt64(code) - UInt64(firstCode)
            guard index <= UInt64(Int.max / 2) else { return nil }
            return uint16(data, at: offset + 20 + Int(index) * 2)

        case 12, 13:
            guard let groupCount = uint32(data, at: offset + 12) else { return nil }
            var lower = 0
            var upper = Int(groupCount)
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let group = offset + 16 + middle * 12
                guard let start = uint32(data, at: group),
                      let end = uint32(data, at: group + 4),
                      let startGlyph = uint32(data, at: group + 8) else { return nil }
                if UInt64(code) < UInt64(start) {
                    upper = middle
                } else if UInt64(code) > UInt64(end) {
                    lower = middle + 1
                } else {
                    let glyph = format == 12
                        ? UInt64(startGlyph) + UInt64(code) - UInt64(start)
                        : UInt64(startGlyph)
                    return glyph <= UInt64(UInt16.max) ? UInt16(glyph) : nil
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func uint8(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard let high = uint8(data, at: offset),
              let low = uint8(data, at: offset + 1) else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard let high = uint16(data, at: offset),
              let low = uint16(data, at: offset + 2) else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }
}
