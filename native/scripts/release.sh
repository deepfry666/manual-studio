#!/bin/zsh
# 发版：改版本号 → 跑测试 → 打包 → 提交并打标签 → 推送 → 在 GitHub 上建 Release 并上传 zip
# 用法：native/scripts/release.sh <版本号> [更新说明文件]
#   例：native/scripts/release.sh 1.1.0 notes.md
#   不给更新说明时，用上一个标签以来的提交记录自动生成。
# 只发原生版；Electron 旧版已定档（标签 electron-v0.1.0-final），不再发版。
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:-}
NOTES=${2:-}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "用法：scripts/release.sh <版本号，如 1.1.0> [更新说明文件]"; exit 1; }
TAG="v$VERSION"
[[ -z $NOTES || -f $NOTES ]] || { echo "找不到更新说明文件：$NOTES"; exit 1; }

git diff --quiet && git diff --cached --quiet || { echo "还有没提交的改动，先提交或撤销再发版"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "标签 $TAG 已经存在"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "GitHub 没登录，先运行：gh auth login -h github.com"; exit 1; }

echo "==> 版本号改成 $VERSION"
PBX=ManualStudio.xcodeproj/project.pbxproj
BUILD=$(( $(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' $PBX | grep -oE '[0-9]+$') + 1 ))
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/" $PBX

echo "==> 测试并打包"
scripts/build-app.sh --test --zip
ZIP="dist/软件指南生成器-$VERSION.zip"
[[ -f $ZIP ]] || { echo "没有生成 $ZIP"; exit 1; }

echo "==> 提交、打标签、推送"
git add $PBX
git commit -m "Release $TAG"
git tag -a "$TAG" -m "软件指南生成器 $VERSION"
git push origin HEAD "$TAG"

echo "==> 创建 GitHub Release"
if [[ -n $NOTES ]]; then
  gh release create "$TAG" "$ZIP" --title "软件指南生成器 $VERSION" --notes-file "$NOTES"
else
  gh release create "$TAG" "$ZIP" --title "软件指南生成器 $VERSION" --generate-notes
fi
echo "==> 完成：$TAG"
