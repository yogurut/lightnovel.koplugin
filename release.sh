#!/usr/bin/env bash
# 发版脚本：在 dev 分支打 tag、生成 zip、创建 GitHub Release
#
# 用法：
#   ./release.sh 0.2.0              # 发版 v0.2.0（prerelease）
#   ./release.sh 0.2.0 stable       # 发正式版
#   ./release.sh 0.2.0 stable "自定义说明"
#
# 前置：
#   - 当前分支必须是 dev（脚本会检查）
#   - /root/.secrets/github-token 存在且有效
set -euo pipefail

REPO="yogurut/lightnovel.koplugin"
VER="${1:?用法: ./release.sh <版本号> [stable] [说明]}"
CHANNEL="${2:-prerelease}"
NOTES_FILE="${3:-}"
TAG="v${VER}"

cd "$(dirname "$0")"

# ---- 检查 ----
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "dev" ]; then
    echo "❌ 当前在 $BRANCH 分支，发版必须在 dev 分支进行"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "❌ 有未提交的改动，请先提交"
    git status --short
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "❌ tag $TAG 已存在"
    exit 1
fi

TOKEN="$(cat /root/.secrets/github-token | tr -d '\n\r ')"
if [ -z "$TOKEN" ]; then
    echo "❌ 读取不到 github token"
    exit 1
fi

# 语法校验，避免把跑不起来的代码发出去
echo "==> 语法校验"
FAIL=0
while IFS= read -r f; do
    if ! luac5.1 -p "$f" 2>/dev/null; then
        echo "  ❌ $f"
        FAIL=1
    fi
done < <(find . -name "*.lua" -not -path "./.git/*" -not -path "./test/menu-stubs/*")
[ "$FAIL" -eq 0 ] && echo "  ✅ 全部通过" || exit 1

# 菜单注册回归测试（防止「插件列表有名字、菜单里找不到」）
echo "==> 菜单注册测试"
if command -v lua5.1 >/dev/null 2>&1; then
    lua5.1 test/test_menu.lua || exit 1
    lua5.1 test/test_probe.lua || exit 1
else
    echo "  ⚠️ 未安装 lua5.1，跳过"
fi

# ---- 打 tag ----
echo "==> 创建 tag $TAG"
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    git tag -a "$TAG" -F "$NOTES_FILE"
else
    git tag -a "$TAG" -m "Release $TAG"
fi

# ---- 推送 ----
echo "==> 推送 dev 分支与 tag"
git push "https://yogurut:${TOKEN}@github.com/${REPO}.git" dev:dev --tags

# ---- 打包 ----
echo "==> 生成 zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git archive --format=tar "$TAG" | (cd "$WORK" && tar xf -)
rm -rf "$WORK/.git"
mv "$WORK" "$WORK/pkg" 2>/dev/null || true
mkdir -p "$WORK/out"
# 重新组织为 lightnovel.koplugin/ 顶层目录
SRC="$(find "$WORK" -maxdepth 2 -name "main.lua" -printf '%h\n' | head -1)"
OUTDIR="$(mktemp -d)/lightnovel.koplugin"
mkdir -p "$OUTDIR"
cp -r "$SRC"/. "$OUTDIR"/
ZIP="/tmp/lightnovel.koplugin-${TAG}.zip"
rm -f "$ZIP"
(cd "$(dirname "$OUTDIR")" && zip -qr "$ZIP" lightnovel.koplugin)
echo "  $ZIP ($(stat -c%s "$ZIP") bytes)"

# ---- 创建 Release ----
echo "==> 创建 GitHub Release"
python3 - "$TOKEN" "$TAG" "$CHANNEL" "$ZIP" "$VER" <<'PY'
import json, sys, urllib.request
token, tag, channel, zip_path, ver = sys.argv[1:6]
notes = f"""## {tag}

### 安装
下载 `lightnovel.koplugin-{tag}.zip`，解压到 `koreader/plugins/`，重启 KOReader。

详见仓库 README 的「测试指南」。
"""
body = json.dumps({
    "tag_name": tag,
    "name": f"{tag}" + (" 开发版" if channel != "stable" else ""),
    "body": notes,
    "draft": False,
    "prerelease": channel != "stable",
}).encode()
req = urllib.request.Request(
    "https://api.github.com/repos/yogurut/lightnovel.koplugin/releases",
    data=body, method="POST",
    headers={"Authorization": "token " + token,
             "Accept": "application/vnd.github+json",
             "Content-Type": "application/json"})
d = json.load(urllib.request.urlopen(req))
print("  Release:", d["html_url"])
open("/tmp/.rel_upload_url", "w").write(d["upload_url"].split("{")[0])
PY

# ---- 上传附件 ----
UP="$(cat /tmp/.rel_upload_url)"
NAME="$(basename "$ZIP")"
curl -s -X POST \
    -H "Authorization: token ${TOKEN}" \
    -H "Content-Type: application/zip" \
    --data-binary "@${ZIP}" \
    "${UP}?name=${NAME}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('  附件:', d.get('name'), d.get('size'), 'bytes')"

echo ""
echo "✅ 发版完成: https://github.com/yogurut/lightnovel.koplugin/releases/tag/${TAG}"
