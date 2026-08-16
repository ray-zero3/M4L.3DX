#!/usr/bin/env bash
#
# shared/patchers/ の共有パッチャーを、それを使う各デバイスの Project へ配る。
#
#   shared-sync.sh            全デバイスへ配布
#   shared-sync.sh --check    差分があるかだけ調べる（CI 用、書き込まない）
#
# Max は「各 Project フォルダに実体がある」前提で依存を解決するため、
# シンボリックリンクや検索パスでは共有できない。実体をコピーするしかない。
#
# 副作用として都合が良い点: 共有パッチャーを直すとコミットが影響デバイス全部の
# パスを触ることになるので、release-please が影響デバイスすべてを自動で
# リリース対象にしてくれる。依存グラフを別に持たなくて済む。

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

drift=0
copied=0

for name in $(list_devices); do
  load_device "$name"
  for rel in ${SHARED[@]+"${SHARED[@]}"}; do
    src="$REPO_ROOT/shared/patchers/$rel"
    dst="$DEVICE_PROJECT/patchers/$rel"

    [ -f "$src" ] || die "$name が参照する共有パッチャーがありません: shared/patchers/$rel"

    if cmp -s "$src" "$dst" 2>/dev/null; then
      continue
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
      warn "未反映: $name ← shared/patchers/$rel"
      drift=1
    else
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      ok "$name ← shared/patchers/$rel"
      copied=$((copied + 1))
    fi
  done
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$drift" -eq 0 ] || die "shared/ の変更が各デバイスに反映されていません。scripts/shared-sync.sh を実行してコミットしてください。"
  ok "共有パッチャーはすべて反映済み"
else
  [ "$copied" -eq 0 ] && info "配布するものはありませんでした（SHARED が空、またはすべて反映済み）"
fi
