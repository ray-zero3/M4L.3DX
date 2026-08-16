#!/usr/bin/env bash
#
# Freeze 済み amxd を、release-please が作ったドラフト Release に添付して公開する。
#
#   release.sh panner-for-8ch          該当デバイスのドラフト Release に添付して公開
#   release.sh panner-for-8ch --keep-draft   添付だけしてドラフトのまま残す
#
# 前提:
#   - release-please の Release PR をマージ済み（タグとドラフト Release が存在する）
#   - Max で Freeze 済みで、scripts/sync.sh dist を実行済み（dist/<name>.amxd がある）
#
# 詳しい手順は RELEASING.md を参照。

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

name="${1:-}"
[ -n "$name" ] || die "使い方: scripts/release.sh <device> [--keep-draft]"
keep_draft=0
[ "${2:-}" = "--keep-draft" ] && keep_draft=1

command -v gh >/dev/null 2>&1 || die "gh コマンドが必要です: brew install gh"
load_device "$name"

artifact="$REPO_ROOT/dist/$name.amxd"
[ -f "$artifact" ] || die "$artifact がありません。
  Max で Freeze してから scripts/sync.sh dist $name を実行してください。"
assert_frozen "$artifact"

# release-please のタグは <component>-v<version> 形式。
# 未公開のドラフトのうち、このデバイスのものを探す。
# gh には jq が組み込まれているので外部の jq は不要。
tag="$(gh release list --limit 100 --json tagName,isDraft \
        --jq "[.[] | select(.isDraft) | select(.tagName | startswith(\"${name}-v\"))] | first | .tagName // empty")"

if [ -z "$tag" ]; then
  die "$name のドラフト Release が見つかりません。
  release-please が出した Release PR をマージしましたか？
  既に公開済みのものに差し替えたい場合は次を直接実行してください:
    gh release upload <tag> dist/$name.amxd --clobber"
fi

info "対象: $tag"
gh release upload "$tag" "$artifact" --clobber
ok "添付しました: dist/$name.amxd"

if [ "$keep_draft" -eq 1 ]; then
  info "--keep-draft のためドラフトのままにします。"
else
  gh release edit "$tag" --draft=false
  ok "公開しました: $(gh release view "$tag" --json url --jq .url)"
fi
