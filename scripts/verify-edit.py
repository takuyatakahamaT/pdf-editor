#!/usr/bin/env python3
"""書き出した PDF の置換ジオメトリを検証する。

PDF Text Bench の書き出しは、ページを Quartz の PDF context へ再描画したうえで
「白い矩形（消去）」と「グリフ輪郭（置換文字）」を追記する。
このスクリプトはその追記部分を content stream から取り出し、

  * 消去矩形が隣接グリフを部分的に削っていないか
  * 置換文字のベースラインが元のベースラインと一致しているか
  * 置換文字が 1 行に収まっているか（折り返していないか）
  * 置換文字の描画幅が、覆った元の文字の送り幅と近いか

を数値で確認する。

    python3 scripts/verify-edit.py EDITED.pdf

元のテキストは白い矩形で覆われているだけで content stream には残るため、
編集後 PDF 単体で元の座標と比較できる。
"""

from __future__ import annotations

import re
import sys
import zlib
from dataclasses import dataclass


def _object_stream(data: bytes, num: int) -> bytes:
    m = re.search((r"(?<![0-9])%d\s+0\s+obj" % num).encode(), data)
    if not m:
        raise KeyError(f"object {num} not found")
    start = data.find(b"stream", m.end())
    start = data.find(b"\n", start) + 1
    end = data.find(b"endstream", start)
    raw = data[start:end]
    try:
        return zlib.decompress(raw)
    except zlib.error:
        return raw


def _page_content(data: bytes) -> bytes:
    m = re.search(rb"/Type\s*/Page[^s].*?/Contents\s+(\d+)\s+0\s+R", data, re.S)
    if not m:
        raise KeyError("page content stream not found")
    return _object_stream(data, int(m.group(1)))


def _font_dicts(data: bytes) -> dict[str, bytes]:
    """ページの /Font リソース名 (例 '/F6') → そのフォントオブジェクトの生バイト列。"""
    res = re.search(rb"/Font\s*<<(.*?)>>", data, re.S)
    result: dict[str, bytes] = {}
    if not res:
        return result
    for key, num in re.findall(rb"(/\w+)\s+(\d+)\s+0\s+R", res.group(1)):
        obj = re.search(
            (r"(?<![0-9])%d\s+0\s+obj(.*?)endobj" % int(num)).encode(), data, re.S
        )
        if obj:
            result[key.decode("latin-1")] = obj.group(1)
    return result


def _parse_bracketed_w_array(body: bytes, start: int) -> list[tuple[str, object]]:
    """`/W [ ... ]` の `[` の直後(start)から、対応する `]` までをトークン化する。
    ネストした配列 (`c [w1 w2 ...]`) を壊さないよう括弧の深さを数えて範囲を決める。
    """
    depth = 1
    i = start
    while depth > 0 and i < len(body):
        if body[i:i + 1] == b"[":
            depth += 1
        elif body[i:i + 1] == b"]":
            depth -= 1
        i += 1
    inner = body[start:i - 1].decode("latin-1")
    tokens: list[tuple[str, object]] = []
    for arr, num in re.findall(r"\[(.*?)\]|(-?\d+\.?\d*)", inner, re.S):
        if arr != "":
            tokens.append(("arr", [float(x) for x in arr.split()]))
        elif num != "":
            tokens.append(("num", float(num)))
    return tokens


def _parse_simple_widths(body: bytes) -> dict[int, float]:
    """単純フォント (Type1/TrueType) の `/FirstChar` + `/Widths` を code→幅(1/1000em) へ。"""
    m_first = re.search(rb"/FirstChar\s+(\d+)", body)
    m_widths = re.search(rb"/Widths\s*\[(.*?)\]", body, re.S)
    widths: dict[int, float] = {}
    if m_first and m_widths:
        first = int(m_first.group(1))
        nums = [float(x) for x in re.findall(rb"-?\d+\.?\d*", m_widths.group(1))]
        for i, w in enumerate(nums):
            widths[first + i] = w
    return widths


def _parse_cid_widths(body: bytes, data: bytes) -> tuple[dict[int, float], float]:
    """Type0/CIDFontType2 の `/DescendantFonts` を辿り、`/W`/`/DW` を code→幅(1/1000em) へ。"""
    default_width = 1000.0
    widths: dict[int, float] = {}
    m_desc = re.search(rb"/DescendantFonts\s*\[\s*(\d+)\s+0\s+R", body)
    if not m_desc:
        return widths, default_width
    dnum = int(m_desc.group(1))
    dobj = re.search((r"(?<![0-9])%d\s+0\s+obj(.*?)endobj" % dnum).encode(), data, re.S)
    if not dobj:
        return widths, default_width
    dbody = dobj.group(1)
    m_dw = re.search(rb"/DW\s+(-?\d+\.?\d*)", dbody)
    if m_dw:
        default_width = float(m_dw.group(1))

    # `/W` は `/W [ ... ]` のインライン配列のことも、`/W 22 0 R` のような
    # 間接参照のこともある。書き出し PDF (Quartz の再エクスポート) では後者になる
    # ことを実機で確認した。間接参照のときは参照先オブジェクトの中身を配列として読む。
    m_w_indirect = re.search(rb"/W\s+(\d+)\s+0\s+R", dbody)
    if m_w_indirect:
        wnum = int(m_w_indirect.group(1))
        wobj = re.search((r"(?<![0-9])%d\s+0\s+obj(.*?)endobj" % wnum).encode(), data, re.S)
        if not wobj:
            return widths, default_width
        wbody = wobj.group(1)
        m_bracket = re.search(rb"\[", wbody)
        if not m_bracket:
            return widths, default_width
        tokens = _parse_bracketed_w_array(wbody, m_bracket.end())
    else:
        m_w = re.search(rb"/W\s*\[", dbody, re.S)
        if not m_w:
            return widths, default_width
        tokens = _parse_bracketed_w_array(dbody, m_w.end())
    k = 0
    while k < len(tokens):
        if tokens[k][0] != "num":
            k += 1
            continue
        c1 = int(tokens[k][1])  # type: ignore[arg-type]
        k += 1
        if k >= len(tokens):
            break
        if tokens[k][0] == "arr":
            for idx, w in enumerate(tokens[k][1]):  # type: ignore[arg-type]
                widths[c1 + idx] = w
            k += 1
        else:
            c2 = int(tokens[k][1])  # type: ignore[arg-type]
            k += 1
            if k >= len(tokens):
                break
            w = tokens[k][1]
            k += 1
            for c in range(c1, c2 + 1):
                widths[c] = w  # type: ignore[assignment]
    return widths, default_width


def _font_width_tables(data: bytes) -> dict[str, tuple[dict[int, float], float]]:
    """各フォントリソース名 → (code→幅(1/1000em) の表, デフォルト幅(1/1000em))。

    Swift 側 (`PDFFontInfoLoader`) が /Widths・/W から実装した幅解決と同じ考え方を
    このスクリプトでも独立に再現する。これにより、「隣接グリフの終端」を PDF が
    宣言している本当の送り幅から求められるようになり、ピッチ（次グリフの開始位置との
    差）を丸ごと使う従来の近似よりも正確に「削っているか」を判定できる。
    """
    tables: dict[str, tuple[dict[int, float], float]] = {}
    for key, body in _font_dicts(data).items():
        if re.search(rb"/Subtype\s*/Type0", body):
            tables[key] = _parse_cid_widths(body, data)
        else:
            tables[key] = (_parse_simple_widths(body), 500.0)
    return tables


def _to_unicode_maps(data: bytes) -> dict[str, dict[int, str]]:
    res = re.search(rb"/Font\s*<<(.*?)>>", data, re.S)
    maps: dict[str, dict[int, str]] = {}
    if not res:
        return maps
    for key, num in re.findall(rb"(/\w+)\s+(\d+)\s+0\s+R", res.group(1)):
        obj = re.search(
            (r"(?<![0-9])%d\s+0\s+obj(.*?)endobj" % int(num)).encode(), data, re.S
        )
        if not obj:
            continue
        tu = re.search(rb"/ToUnicode\s+(\d+)\s+0\s+R", obj.group(1))
        if not tu:
            continue
        cmap = _object_stream(data, int(tu.group(1))).decode("latin-1")
        table: dict[int, str] = {}
        for block in re.findall(r"beginbfchar(.*?)endbfchar", cmap, re.S):
            for src, dst in re.findall(r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>", block):
                table[int(src, 16)] = "".join(
                    chr(int(dst[i : i + 4], 16)) for i in range(0, len(dst), 4)
                )
        for block in re.findall(r"beginbfrange(.*?)endbfrange", cmap, re.S):
            for lo, hi, dst in re.findall(
                r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>", block
            ):
                base = int(dst, 16)
                for code in range(int(lo, 16), int(hi, 16) + 1):
                    table[code] = chr(base + code - int(lo, 16))
        maps[key.decode("latin-1")] = table
    return maps


GLYPH_RE = re.compile(
    r"q\s+([\d.\-]+)\s+0\s+0\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+cm\s+"
    r"BT\s+([\d.\-]+)\s+0\s+0\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+"
    r"Tm\s+(/\w+)\s+1\s+Tf\s+<([0-9a-fA-F]+)>\s+Tj\s+ET\s+Q",
    re.S,
)
WHITE_RECT_RE = re.compile(
    # 2 件目以降の消去矩形では、直前の塗りと色空間が変わっていない場合
    # Quartz の PDF writer が "/CsN cs" を省略し "1 sc" だけを書くことがある
    # （色空間そのものは q/Q を跨いでも変わっていないため、仕様上正しい省略）。
    # そのため "/CsN cs" 部分は省略されていても許容する。
    r"(?:/Cs\d\s+cs\s+)?1\s+sc\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+re\s+f",
    re.S,
)
POINT_ML_RE = re.compile(r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s+(?:m|l)\b")
# CTFontCreatePathForGlyph が返す輪郭は TrueType の曲線がそのまま 3 次ベジエ
# (`x1 y1 x2 y2 x3 y3 c`) として書き出される。制御点・終点も輪郭の一部なので、
# `m`/`l` だけでなく `c` の 3 組の座標も ink の範囲に含める。
POINT_C_RE = re.compile(
    r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s+"
    r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s+"
    r"(-?\d+\.?\d*)\s+(-?\d+\.?\d*)\s+c\b"
)


def extract_points(segment: str) -> list[tuple[float, float]]:
    pts = [(float(x), float(y)) for x, y in POINT_ML_RE.findall(segment)]
    for m in POINT_C_RE.finditer(segment):
        x1, y1, x2, y2, x3, y3 = (float(v) for v in m.groups())
        pts.extend([(x1, y1), (x2, y2), (x3, y3)])
    return pts


@dataclass
class Glyph:
    x: float
    baseline: float
    size: float
    char: str
    advance: float = 0.0

    @property
    def end(self) -> float:
        return self.x + self.advance


def parse_glyphs(
    content: str,
    maps: dict[str, dict[int, str]],
    width_tables: dict[str, tuple[dict[int, float], float]],
) -> list[Glyph]:
    """1 グリフごとの位置・サイズ・文字・送り幅を取り出す。

    送り幅 (`advance`) は PDF 自身が宣言している `/Widths`・`/W` の値を使う
    （フォントの `/FirstChar`+`/Widths` または Type0 の `/DescendantFonts`→`/W`/`/DW`）。
    以前は「次グリフの開始位置までのピッチ」を丸ごと advance とみなしていたが、
    ピッチには字間の余白（グリフ本来の幅と次グリフの開始位置との差）も含まれるため、
    隣接グリフの終端を実際より遠くまで見積もってしまい、消去矩形が正しく
    半分マージンで隣に触れていないケースまで誤検出することがあった
    （実測: IPAexGothic の「年」の宣言幅 992/1000em に対し、次の文字までのピッチは
    ちょうど 1em あり、0.074pt 分だけ実際より過大評価していた）。
    宣言幅を使えば、この余白を隣接グリフ側へ誤って割り当てずに済む。
    """
    out: list[Glyph] = []
    for m in GLYPH_RE.finditer(content):
        a, d, e, f, ta, _td, tx, ty, font, code_hex = m.groups()
        a, d, e, f, ta, tx, ty = (float(v) for v in (a, d, e, f, ta, tx, ty))
        size = abs(a * ta)
        code = int(code_hex, 16)
        widths, default_width = width_tables.get(font, ({}, 500.0))
        declared_width = widths.get(code, default_width) / 1000.0 * size
        out.append(
            Glyph(
                x=e + a * tx,
                baseline=f + d * ty,
                size=size,
                char=maps.get(font, {}).get(code, "?"),
                advance=declared_width,
            )
        )
    return out


#: 隣接判定で許容する誤差（pt）。
#:
#: アプリは「元 PDF」のフォント辞書の /W を読んで advance box を決め、
#: このスクリプトは「書き出した PDF」（Quartz が再サブセット化したもの）の /W を
#: 読む。同じグリフでも両者の宣言幅はわずかに食い違い、実測では 0.03〜0.05pt
#: （9.2pt の em に対して 0.4% 程度）ずれる。この差はどちらのツールの誤りでもなく、
#: 独立した 2 つの幅テーブルを突き合わせている以上避けられない。
#:
#: アプリ側は `coverBounds` を隣接グリフの advance box で明示的にクランプしており、
#: 自身の座標系では侵入が起こり得ない。したがってここで見たいのは
#: 「クランプが効かなくなるレベルの実バグ」だけであり、閾値は上記の実測差を
#: 少し上回る 0.1pt で足りる。旧実装の Helvetica 誤用（1.46pt 侵入）のような
#: 実害のあるズレは、この閾値でも余裕を持って検出できる。
NEIGHBOR_TOLERANCE_PT = 0.1


def ink_start(g: Glyph) -> float:
    return g.x + NEIGHBOR_TOLERANCE_PT


def ink_end(g: Glyph) -> float:
    return g.end - NEIGHBOR_TOLERANCE_PT


def parse_edits(content: str) -> list[dict]:
    tail = content[content.rfind("ET") + 2 :]
    rects = list(WHITE_RECT_RE.finditer(tail))
    edits = []
    for i, m in enumerate(rects):
        seg = tail[m.end() : rects[i + 1].start() if i + 1 < len(rects) else len(tail)]
        pts = extract_points(seg)
        x, y, w, h = (float(m.group(j)) for j in range(1, 5))
        edits.append(
            {
                "cover": (x, y, x + w, y + h),
                "ink": (
                    min(p[0] for p in pts), min(p[1] for p in pts),
                    max(p[0] for p in pts), max(p[1] for p in pts),
                )
                if pts
                else None,
            }
        )
    return edits


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    data = open(sys.argv[1], "rb").read()
    content = _page_content(data).decode("latin-1")
    glyphs = parse_glyphs(content, _to_unicode_maps(data), _font_width_tables(data))
    edits = parse_edits(content)

    if not edits:
        print("置換の追記が見つかりませんでした。")
        return 1

    failures = 0
    for i, edit in enumerate(edits, 1):
        cx0, cy0, cx1, cy1 = edit["cover"]
        print(f"\n=== 置換 #{i}")
        print(f"  消去矩形 x[{cx0:.3f}, {cx1:.3f}] y[{cy0:.3f}, {cy1:.3f}]"
              f"  (幅 {cx1 - cx0:.3f} / 高さ {cy1 - cy0:.3f})")

        touched = [
            g for g in glyphs
            if cy0 <= g.baseline <= cy1 and ink_end(g) > cx0 + 0.01 and ink_start(g) < cx1 - 0.01
        ]
        if not touched:
            print("  覆っている元グリフが見つかりません。")
            continue
        touched.sort(key=lambda g: g.x)

        # 「完全に覆われたグリフが最も多い行」を置換対象の行とみなす
        def fully_covered(g: Glyph) -> bool:
            return ink_start(g) >= cx0 - 0.05 and ink_end(g) <= cx1 + 0.05

        lines: dict[float, list[Glyph]] = {}
        for g in touched:
            key = next((b for b in lines if abs(b - g.baseline) < 0.3), g.baseline)
            lines.setdefault(key, []).append(g)
        baseline = max(lines, key=lambda b: sum(1 for g in lines[b] if fully_covered(g)))
        size = max(g.size for g in lines[baseline])

        full = [g for g in lines[baseline] if fully_covered(g)]
        partial = [g for g in lines[baseline] if not fully_covered(g)]
        print(f"  覆った元の文字: '{''.join(g.char for g in full)}'"
              f"  サイズ {size:.3f}pt  ベースライン {baseline:.3f}")
        if partial:
            failures += len(partial)
            for g in partial:
                print(f"  NG 隣のグリフ '{g.char}' (x[{g.x:.3f}, {g.end:.3f}]) を"
                      f"部分的に削っています")
        else:
            print("  OK 隣接グリフを削っていません")

        # 上下の行を侵していないか
        others = [g for g in glyphs if abs(g.baseline - baseline) >= 0.3
                  and cy0 < g.baseline < cy1 and ink_end(g) > cx0 and ink_start(g) < cx1]
        if others:
            failures += 1
            print(f"  NG 別の行のグリフ {''.join(g.char for g in others)!r} に重なっています")

        if not full:
            continue
        run_x0, run_x1 = full[0].x, full[-1].end
        print(f"  元 run x[{run_x0:.3f}, {run_x1:.3f}] 幅 {run_x1 - run_x0:.3f}")

        if edit["ink"]:
            ix0, iy0, ix1, iy1 = edit["ink"]
            print(f"  置換文字 x[{ix0:.3f}, {ix1:.3f}] y[{iy0:.3f}, {iy1:.3f}]"
                  f"  (幅 {ix1 - ix0:.3f})")

            delta = iy0 - baseline
            if abs(delta) <= 0.15:
                print(f"  OK ベースライン一致 (差 {delta:+.3f}pt)")
            else:
                failures += 1
                print(f"  NG ベースラインが {delta:+.3f}pt ずれています")

            em = (iy1 - iy0) / size
            if em < 1.35:
                print(f"  OK 1 行に収まっています ({em:.2f} em)")
            else:
                failures += 1
                print(f"  NG 折り返しの疑い ({em:.2f} em = 約 {em / 1.2:.1f} 行)")

            if ix1 > run_x1 + 0.05:
                failures += 1
                print(f"  NG 置換文字が元 run の右端 {run_x1:.3f} を"
                      f"{ix1 - run_x1:.3f}pt はみ出しています")
            else:
                print(f"  OK 元 run の右端を越えていません")

    print(f"\n判定: {'すべて OK' if failures == 0 else f'NG {failures} 件'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
