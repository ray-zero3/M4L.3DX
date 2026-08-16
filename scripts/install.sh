#!/usr/bin/env bash
#
# clone したリポジトリから、この Mac の Live / Max へデバイスを導入する。
# 編集できる unfrozen の状態で入るので、そのまま開発を続けられる。
#
#   scripts/install.sh                    全デバイスを導入
#   scripts/install.sh --device <name>    1つだけ導入
#   scripts/install.sh --dry-run          何をするか表示するだけ
#   scripts/install.sh --yes              確認プロンプトを出さない
#
# 使うだけなら導入は不要です。GitHub Releases から frozen amxd を落として
# Live にドラッグしてください（README 参照）。
#
# 配置先を変えたいとき:
#   M4L_USER_LIBRARY=... M4L_MAX_DEVICES=... scripts/install.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
ASSUME_YES=0
ONLY=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --device)  shift; ONLY="${1:-}" ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *)         die "不明なオプション: $1" ;;
  esac
  shift
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '       $ %s\n' "$*" >&2
  else
    "$@"
  fi
}

# ------------------------------------------------------------ 前提の確認
info "配置先を確認します"
require_paths
show_paths

if [ -n "$ONLY" ]; then
  [ -f "$REPO_ROOT/devices/$ONLY/device.conf" ] || die "そんなデバイスはありません: $ONLY"
  DEVICES="$ONLY"
else
  DEVICES="$(list_devices)"
fi
[ -n "$DEVICES" ] || die "devices/ にデバイスがありません"

# ---------------------------------------------------- 必要プラグインの確認
printf '\n' >&2
info "必要な外部プラグインを確認します"
plugin_missing=0
for name in $DEVICES; do
  load_device "$name"
  for rec in ${PLUGINS[@]+"${PLUGINS[@]}"}; do
    pname="$(field "$rec" 1)"
    bundle="$(field "$rec" 2)"
    url="$(field "$rec" 3)"
    need="$(field "$rec" 4)"
    if plugin_installed "$bundle"; then
      ok "$pname"
    elif [ "$need" = "required" ]; then
      warn "$pname が見つかりません（$name に必須）
       $bundle が VST3 フォルダにありません。
       これは有償プラグインです。購入・インストールしてください: $url
       ※ インストールしないとデバイスは音を出しません。"
      plugin_missing=1
    else
      warn "$pname が見つかりません（$name では任意）: $url"
    fi
  done
done

# ------------------------------------------- Ableton 由来ファイルの取り込み
printf '\n' >&2
info "Ableton 公式デバイス由来のパッチャーを取得します"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '       $ %s\n' "scripts/sync.sh vendor $DEVICES" >&2
else
  # shellcheck disable=SC2086
  "$REPO_ROOT/scripts/sync.sh" vendor $DEVICES
fi

# ------------------------------------------------ 共有パッチャーの取り込み
if [ "$DRY_RUN" -eq 1 ]; then
  printf '       $ %s\n' "scripts/shared-sync.sh" >&2
else
  "$REPO_ROOT/scripts/shared-sync.sh"
fi

# ---------------------------------------------------------------- 確認
printf '\n' >&2
info "次のファイルを配置します"
for name in $DEVICES; do
  load_device "$name"
  printf '       %s\n' "$LIVE_AMXD" >&2
  printf '       %s/\n' "$LIVE_PROJECT" >&2
done

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  printf '\n既存のファイルはバックアップしてから上書きします。続けますか? [y/N] ' >&2
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "中止しました" ;;
  esac
fi

# ------------------------------------------------------------ バックアップ
BACKUP_DIR="${M4L_BACKUP_DIR:-$HOME/.m4l-3dx-backups}/$(date +%Y%m%d-%H%M%S)"
backup() { # backup <path>
  [ -e "$1" ] || return 0
  local rel dest
  rel="$(basename "$1")"
  dest="$BACKUP_DIR/$rel"
  run mkdir -p "$BACKUP_DIR"
  run cp -R "$1" "$dest"
  warn "退避: $rel → $BACKUP_DIR/"
}

# ---------------------------------------------------------------- 配置
printf '\n' >&2
info "配置します"
for name in $DEVICES; do
  load_device "$name"
  build_excludes

  [ -f "$DEVICE_AMXD" ] || die "$DEVICE_AMXD がありません。リポジトリが壊れています。"
  assert_unfrozen "$DEVICE_AMXD"

  backup "$LIVE_AMXD"
  backup "$LIVE_PROJECT"

  run mkdir -p "$LIVE_PROJECT"
  run rsync -a "$DEVICE_AMXD" "$LIVE_AMXD"
  run rsync -a "${EXCLUDES[@]}" "$DEVICE_PROJECT/" "$LIVE_PROJECT/"
  ok "$name"
done

# ---------------------------------------------------------------- 結果
printf '\n' >&2
if [ "$DRY_RUN" -eq 1 ]; then
  info "--dry-run のため何も書き込んでいません。"
  exit 0
fi

ok "導入が完了しました。"
printf '
  Live のブラウザ → Categories → Max for Live → Max Audio Effect
  に次のデバイスが出ます:
' >&2
for name in $DEVICES; do printf '    - %s\n' "$name" >&2; done

if [ "$plugin_missing" -eq 1 ]; then
  printf '\n' >&2
  warn "必須プラグインが未インストールです。上の案内を確認してください。"
fi

if [ -d "$BACKUP_DIR" ]; then
  printf '\n' >&2
  info "上書きしたファイルの退避先: $BACKUP_DIR"
fi
