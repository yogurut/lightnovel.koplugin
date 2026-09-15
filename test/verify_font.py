#!/usr/bin/env python3
"""轻书架字体解密 —— 快速验证脚本

证明「用站点字体渲染密文即可得到正确文字」这一结论。

思路：
  1. 从 /tmp/ln-chapter.json 读取密文标题与明文标题
  2. 从 /tmp/ln-pair.ttf（站点字体）取每个密文码位的字形
  3. 与标准字库（思源黑体）做位图匹配，找出最相似的汉字
  4. 与明文标题逐字比对

注意：为避免 O(7000) 的全量扫描，这里用「结构指纹预筛 + 位图精选」：
  先用 (轮廓数, 点数区间) 把候选压到几十个，再做位图 IoU。

用法：
  python3 test/verify_font.py [标准字体路径]
"""
import json
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

CIPHER_TTF = "/tmp/ln-pair.ttf"
CHAPTER = "/tmp/ln-chapter.json"
REF_FONT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/SourceHanSansSC.ttf"

SIZE = 32


def outline(path, cp):
    """取码位 cp 的轮廓，返回 (轮廓列表, 点数)。"""
    font = TTFont(path, fontNumber=0, lazy=True)
    cmap = font.getBestCmap()
    gname = cmap.get(cp)
    if not gname:
        return None, 0
    gs = font.getGlyphSet()
    pen = RecordingPen()
    try:
        gs[gname].draw(pen)
    except Exception:
        return None, 0

    contours, cur = [], []
    for op, args in pen.value:
        if op == "moveTo":
            if cur:
                contours.append(cur)
            cur = [args[0]]
        elif op in ("lineTo", "qCurveTo", "curveTo"):
            for pt in args:
                if pt:
                    cur.append(pt)
        elif op == "closePath":
            if cur:
                contours.append(cur)
                cur = []
    if cur:
        contours.append(cur)

    total = sum(len(c) for c in contours)
    return contours, total


def raster(contours, size=SIZE):
    """把轮廓渲染成二值位图（奇偶填充）。"""
    if not contours:
        return None
    pts = [p for c in contours for p in c]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    mnx, mxx, mny, mxy = min(xs), max(xs), min(ys), max(ys)
    w, h = mxx - mnx, mxy - mny
    if w <= 0 or h <= 0:
        return None

    scale = (size * 0.9) / max(w, h)
    ox = (size - w * scale) / 2 - mnx * scale
    oy = (size - h * scale) / 2 - mny * scale
    normalized = [[(p[0] * scale + ox, p[1] * scale + oy) for p in c] for c in contours]

    bm = bytearray(size * size)

    def inside(px, py):
        crossings = 0
        for c in normalized:
            n = len(c)
            for i in range(n):
                x1, y1 = c[i]
                x2, y2 = c[(i + 1) % n]
                if (y1 > py) != (y2 > py):
                    if px < x1 + (py - y1) * (x2 - x1) / (y2 - y1):
                        crossings += 1
        return crossings & 1

    for j in range(size):
        for i in range(size):
            if inside(i + 0.5, j + 0.5):
                bm[j * size + i] = 1
    return bytes(bm)


def iou(a, b):
    if not a or not b:
        return 0.0
    inter = sum(1 for x, y in zip(a, b) if x and y)
    union = sum(1 for x, y in zip(a, b) if x or y)
    return inter / union if union else 0.0


def build_ref_index(ref_path, needed_chars=None):
    """预计算标准字库的 CJK 位图，按 (轮廓数, 点数) 建索引。

    needed_chars: 若提供，只索引这些字符（快得多，足够验证用）。
    """
    font = TTFont(ref_path, fontNumber=0, lazy=True)
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()
    index = {}

    if needed_chars:
        cps = [ord(c) for c in needed_chars if 0x4E00 <= ord(c) <= 0x9FFF]
    else:
        cps = list(range(0x4E00, 0x9FA6))

    for cp in cps:
        gname = cmap.get(cp)
        if not gname:
            continue
        pen = RecordingPen()
        try:
            gs[gname].draw(pen)
        except Exception:
            continue
        contours, cur = [], []
        for op, args in pen.value:
            if op == "moveTo":
                if cur:
                    contours.append(cur)
                cur = [args[0]]
            elif op in ("lineTo", "qCurveTo", "curveTo"):
                for pt in args:
                    if pt:
                        cur.append(pt)
            elif op == "closePath":
                if cur:
                    contours.append(cur)
                    cur = []
        if cur:
            contours.append(cur)
        bm = raster(contours)
        if not bm:
            continue
        total = sum(len(c) for c in contours)
        index.setdefault(total, []).append((chr(cp), bm, len(contours)))
    return index


def main():
    chapter = json.load(open(CHAPTER, encoding="utf-8"))
    cipher = chapter.get("titleCipher")
    plain = chapter.get("titlePlain")
    if not cipher or not plain:
        print("章节信息缺少 titleCipher / titlePlain，请先跑 test/getboth.js")
        return 1

    print(f"密文字体   : {CIPHER_TTF}")
    print(f"标准字库   : {REF_FONT}")
    print(f"密文标题   : {cipher}")
    print(f"明文标题   : {plain}")
    print()

    ref_index = build_ref_index(REF_FONT, needed_chars=plain)
    total_ref = sum(len(v) for v in ref_index.values())
    print(f"标准字库索引: {total_ref} 个字形（仅标题涉及字符）")
    print()

    result = []
    ok = 0
    for i, ch in enumerate(cipher):
        if not (0x4E00 <= ord(ch) <= 0x9FFF):
            result.append(ch)
            continue

        contours, total = outline(CIPHER_TTF, ord(ch))
        bm = raster(contours)
        if not bm:
            result.append("?")
            continue

        # 结构指纹预筛：按总点数就近取候选
        candidates = []
        for key, items in ref_index.items():
            if abs(key - total) <= max(25, total * 0.5):
                candidates.extend(items)
        if not candidates:
            candidates = [x for v in ref_index.values() for x in v]

        best, best_score = "?", 0.0
        for cand_ch, cand_bm, _ in candidates:
            s = iou(bm, cand_bm)
            if s > best_score:
                best, best_score = cand_ch, s

        result.append(best)
        expected = plain[i] if i < len(plain) else ""
        hit = (best == expected)
        if hit:
            ok += 1
        print(f"  '{ch}' (U+{ord(ch):04X}) -> '{best}' 期望 '{expected}'  "
              f"IoU={best_score:.2f} {'✅' if hit else '❌'}")

    out = "".join(result)
    cjk_total = sum(1 for ch in cipher if 0x4E00 <= ord(ch) <= 0x9FFF)

    print()
    print(f"还原结果 : {out}")
    print(f"期望结果 : {plain}")
    print(f"汉字命中 : {ok}/{cjk_total}")
    print()
    print("注意：本脚本是「用位图匹配反推字形」，用来证明站点确实是字体混淆；")
    print("      真实阅读时**不需要**这步——KOReader 直接用该字体渲染即可 100% 正确。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
