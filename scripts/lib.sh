#!/usr/bin/env bash
# 全スクリプト共通のヘルパー。単体実行はせず source して使う。
#
# 外部依存は rsync / find / shasum のみ（すべて macOS 標準）。
# デバイスのマニフェストは JSON ではなく shell が直接 source できる
# devices/<name>/device.conf にしてあるため、jq や node は不要。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------- ログ出力
_sgr() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || true; }
info() { _sgr 36; printf '==> ' >&2; _sgr 0; printf '%s\n' "$*" >&2; }
ok()   { _sgr 32; printf ' ok  ' >&2; _sgr 0; printf '%s\n' "$*" >&2; }
warn() { _sgr 33; printf 'warn ' >&2; _sgr 0; printf '%s\n' "$*" >&2; }
die()  { _sgr 31; printf 'error ' >&2; _sgr 0; printf '%s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------- 配置先パスの解決
# 環境変数 M4L_USER_LIBRARY / M4L_MAX_DEVICES で上書きできる。
# 別マシンで Max のバージョンや User Library の場所が違う場合に使う。

_default_user_library() {
  printf '%s' "$HOME/Music/Ableton/User Library/Presets/Audio Effects/Max Audio Effect"
}

# ~/Documents/Max 8, Max 9, Max 10 ... のうち最も新しいバージョンを選ぶ。
# 単純な glob だと "Max 10" が "Max 9" より前に来てしまうため sort -V を使う。
_default_max_devices() {
  local newest="" dir
  while IFS= read -r dir; do
    [ -d "$dir/Max for Live Devices" ] && newest="$dir/Max for Live Devices"
  done < <(find "$HOME/Documents" -maxdepth 1 -type d -name 'Max [0-9]*' 2>/dev/null | sort -V)
  printf '%s' "$newest"
}

USER_LIBRARY="${M4L_USER_LIBRARY:-$(_default_user_library)}"
MAX_DEVICES="${M4L_MAX_DEVICES:-$(_default_max_devices)}"

require_paths() {
  [ -n "$MAX_DEVICES" ] || die "Max for Live Devices フォルダを自動検出できませんでした。
  環境変数 M4L_MAX_DEVICES で指定してください。"
  [ -d "$USER_LIBRARY" ] || die "Live の User Library が見つかりません:
  $USER_LIBRARY
  環境変数 M4L_USER_LIBRARY で指定してください。"
  [ -d "$MAX_DEVICES" ] || die "Max for Live Devices が見つかりません:
  $MAX_DEVICES
  環境変数 M4L_MAX_DEVICES で指定してください。"
}

show_paths() {
  info "User Library : $USER_LIBRARY"
  info "Max Devices  : $MAX_DEVICES"
}

# ------------------------------------------------------------ デバイス列挙
list_devices() {
  local dir
  for dir in "$REPO_ROOT"/devices/*/; do
    [ -f "$dir/device.conf" ] || continue
    basename "$dir"
  done
}

# load_device <name>
# device.conf を読み込み、DEVICE_* と SHARED / VENDOR / PLUGINS / IGNORE を設定する。
load_device() {
  local name="$1"
  local conf="$REPO_ROOT/devices/$name/device.conf"
  [ -f "$conf" ] || die "device.conf がありません: $conf"

  # 前のデバイスの値が残らないよう毎回リセットする
  DESCRIPTION=""
  SHARED=()
  VENDOR=()
  PLUGINS=()
  IGNORE=()

  # shellcheck disable=SC1090
  source "$conf"

  DEVICE_NAME="$name"
  DEVICE_DIR="$REPO_ROOT/devices/$name"
  DEVICE_AMXD="$DEVICE_DIR/$name.amxd"
  DEVICE_PROJECT="$DEVICE_DIR/$name Project"
  LIVE_AMXD="$USER_LIBRARY/$name.amxd"
  LIVE_PROJECT="$MAX_DEVICES/$name Project"
}

# "a|b|c" 形式のレコードから n 番目のフィールドを取り出す
field() {
  local rec="$1" n="$2"
  printf '%s' "$rec" | cut -d'|' -f"$n"
}

# ---------------------------------------------------------- frozen 判定
# frozen な amxd は依存ファイルを埋め込むため JSON に "dependency_cache" を持つ。
# User Library 内の配布デバイス（BiP, ClipGain 等）で実際に確認済み。
# amxd 末尾に NUL があり grep がバイナリと判定するため -a を付ける。
is_frozen() {
  [ -f "$1" ] || return 1
  LC_ALL=C grep -qa '"dependency_cache"' "$1"
}

assert_unfrozen() {
  if is_frozen "$1"; then
    die "$(basename "$1") は frozen です。
  frozen な amxd をソースに取り込むと差分が読めなくなります。
  Max のツールバーの雪の結晶アイコンで Unfreeze し、保存してからやり直してください。"
  fi
}

assert_frozen() {
  if ! is_frozen "$1"; then
    die "$(basename "$1") は frozen ではありません。
  unfrozen な amxd を配布すると、他人の環境では依存パッチャーが見つからず動きません。
  Max のツールバーの雪の結晶アイコンで Freeze し、保存してからやり直してください。"
  fi
}

# ------------------------------------------------------- rsync の除外条件
# ロード済みデバイスの IGNORE から EXCLUDES 配列を組み立てる。
#
# vendor ファイルはここでは除外しない。作業ツリーには実体があってほしい
# （ないとデバイスが動かない）が、追跡はしたくない、という要求なので
# .gitignore 側で解決している。rsync は現実をそのままミラーする。
build_excludes() {
  EXCLUDES=(
    --exclude '.DS_Store'
    --exclude 'Icon?'
    # Max がプロジェクト整理（Consolidate / Freeze 前後）で作る作業フォルダ。
    # 中身は既存ファイルの退避コピーなので追跡しない。
    --exclude 'discarded/'
    --exclude 'duplicates/'
  )
  local rec
  for rec in ${IGNORE[@]+"${IGNORE[@]}"}; do
    EXCLUDES+=( --exclude "$rec" )
  done
}

# ------------------------------------------------------------ プラグイン
# VST3 が macOS の標準パスに存在するか調べる。
plugin_installed() {
  local bundle="$1"
  [ -e "/Library/Audio/Plug-Ins/VST3/$bundle" ] ||
  [ -e "$HOME/Library/Audio/Plug-Ins/VST3/$bundle" ]
}

sha1_of() { shasum -a 1 "$1" | awk '{print $1}'; }
