#!/usr/bin/env bash
#
# スクリプト群のスモークテスト。
#
# install.sh と sync.sh はあなたの実際の Live / Max フォルダに書き込むので、
# ここでは M4L_USER_LIBRARY / M4L_MAX_DEVICES を一時ディレクトリへ向けて
# 隔離した砂場で動かす。実環境には一切触れない。
#
#   scripts/test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/m4l-3dx-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

# 対象はサブシェルで動かす。lib.sh の die は exit するので、
# 現在のシェルで直接呼ぶとテスト本体ごと落ちてしまう。
check() { # check <説明> <コマンド...>
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s\n' "$desc"
    fail=$((fail + 1))
  fi
}

check_fails() { # 失敗することを期待する
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    printf '  \033[31mFAIL\033[0m %s（成功してしまった）\n' "$desc"
    fail=$((fail + 1))
  else
    printf '  \033[32mPASS\033[0m %s\n' "$desc"
    pass=$((pass + 1))
  fi
}

# lib.sh を読み込んだ別プロセスで式を評価する。
# bash -c は新しいプロセスなので、test.sh 側の source は引き継がれない。
libsh() { bash -c "source '$REPO_ROOT/scripts/lib.sh'; $1"; }

# ------------------------------------------------------------ 砂場の準備
export M4L_USER_LIBRARY="$SANDBOX/UserLibrary"
export M4L_MAX_DEVICES="$SANDBOX/MaxDevices"
export M4L_BACKUP_DIR="$SANDBOX/backups"
mkdir -p "$M4L_USER_LIBRARY" "$M4L_MAX_DEVICES/Audio Sends Project/patchers"

# vendor の取得元を用意する。実機に本物があればそれを使う（sha1 検証まで通る）。
# なければダミーで代用し、コピー処理そのものだけを検証する。
REAL_SENDS=""
for d in "$HOME/Documents/Max "*/"Max for Live Devices/Audio Sends Project/patchers"; do
  [ -f "$d/SendsRouting.maxpat" ] && REAL_SENDS="$d"
done
if [ -n "$REAL_SENDS" ]; then
  cp "$REAL_SENDS/SendsRouting.maxpat" "$REAL_SENDS/RoutingObjects2.maxpat" \
     "$M4L_MAX_DEVICES/Audio Sends Project/patchers/"
  echo "  (vendor の取得元に実機のファイルを使用)"
else
  printf 'dummy sends\n'   > "$M4L_MAX_DEVICES/Audio Sends Project/patchers/SendsRouting.maxpat"
  printf 'dummy routing\n' > "$M4L_MAX_DEVICES/Audio Sends Project/patchers/RoutingObjects2.maxpat"
  echo "  (vendor の取得元にダミーを使用。sha1 不一致の警告は想定内)"
fi

echo
echo "== 構文チェック =="
for f in "$REPO_ROOT"/scripts/*.sh; do
  check "bash -n $(basename "$f")" bash -n "$f"
done

echo
echo "== lib.sh =="
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

check "デバイスを2つ列挙できる" libsh '[ "$(list_devices | wc -l | tr -d " ")" = "2" ]'
check "device.conf を読める" libsh 'load_device panner-for-8ch; [ -n "$DESCRIPTION" ]'
check "load_device で前のデバイスの値が残らない" libsh '
  load_device panner-for-8ch
  load_device 8to2ch-hpl
  [ "$DEVICE_NAME" = "8to2ch-hpl" ] && [ "${#VENDOR[@]}" = 2 ]'
check "field でレコードを分解できる" libsh '[ "$(field "a|b|c" 2)" = "b" ]'
check "配置先を環境変数で上書きできる" libsh \
  '[ "$USER_LIBRARY" = "$M4L_USER_LIBRARY" ] && [ "$MAX_DEVICES" = "$M4L_MAX_DEVICES" ]'

echo
echo "== frozen 判定 =="
printf '{ "patcher": {} }\n' > "$SANDBOX/unfrozen.amxd"
printf '{ "patcher": { "dependency_cache": [] } }\n' > "$SANDBOX/frozen.amxd"
check       "frozen を検出できる"          is_frozen "$SANDBOX/frozen.amxd"
check_fails "unfrozen を frozen と誤判定しない" is_frozen "$SANDBOX/unfrozen.amxd"
check       "assert_unfrozen は unfrozen を通す" assert_unfrozen "$SANDBOX/unfrozen.amxd"
check_fails "assert_unfrozen は frozen を弾く"   assert_unfrozen "$SANDBOX/frozen.amxd"
check       "assert_frozen は frozen を通す"     assert_frozen "$SANDBOX/frozen.amxd"
check_fails "assert_frozen は unfrozen を弾く"   assert_frozen "$SANDBOX/unfrozen.amxd"

# 実際に追跡している amxd がすべて unfrozen であること
for f in "$REPO_ROOT"/devices/*/*.amxd; do
  [ -f "$f" ] || continue
  check_fails "追跡中の $(basename "$f") は unfrozen" is_frozen "$f"
done

echo
echo "== sync.sh =="
check_fails "取得元がないと vendor は明確に失敗する" \
  env M4L_MAX_DEVICES="$SANDBOX/empty" "$REPO_ROOT/scripts/sync.sh" vendor
check "vendor が vendor ファイルを配置する" "$REPO_ROOT/scripts/sync.sh" vendor
check "  → SendsRouting.maxpat が置かれた" \
  test -f "$REPO_ROOT/devices/panner-for-8ch/panner-for-8ch Project/patchers/SendsRouting.maxpat"
check "  → ReceivesRouting.maxpat が置かれた（Sends からのリネーム）" \
  test -f "$REPO_ROOT/devices/8to2ch-hpl/8to2ch-hpl Project/patchers/ReceivesRouting.maxpat"
check_fails "存在しないデバイス名を弾く" \
  "$REPO_ROOT/scripts/sync.sh" pull no-such-device

echo
echo "== shared-sync.sh =="
check "SHARED が空でも --check が通る" "$REPO_ROOT/scripts/shared-sync.sh" --check

echo
echo "== 除外設定 =="
check "build_excludes が Max の作業フォルダを除外する" libsh '
  load_device panner-for-8ch; build_excludes
  printf "%s\n" "${EXCLUDES[@]}" | grep -qx "discarded/" &&
  printf "%s\n" "${EXCLUDES[@]}" | grep -qx "duplicates/"'
check "build_excludes が device.conf の IGNORE を反映する" libsh '
  load_device panner-for-8ch; build_excludes
  printf "%s\n" "${EXCLUDES[@]}" | grep -qx "data/HPL Processor Ultimate.maxsnap"'
for name in $(list_devices); do
  load_device "$name"
  [ -d "$DEVICE_PROJECT" ] || continue
  check_fails "$name: 除外対象の maxsnap が取り込まれていない" \
    test -f "$DEVICE_PROJECT/data/HPL Processor Ultimate.maxsnap"
  check_fails "$name: Max の作業フォルダが取り込まれていない" \
    test -d "$DEVICE_PROJECT/discarded"
done

# amxd が揃っているデバイスだけ導入テストの対象にする
READY=()
for name in $(list_devices); do
  load_device "$name"
  [ -f "$DEVICE_AMXD" ] && READY+=("$name")
done

echo
echo "== install.sh =="
if [ "${#READY[@]}" -eq 0 ]; then
  echo "  SKIP  取り込み済みの amxd がないため導入テストを飛ばします"
else
  target="${READY[0]}"
  echo "  (対象: $target)"
  check "--dry-run が完走する" \
    "$REPO_ROOT/scripts/install.sh" --dry-run --yes --device "$target"
  check_fails "--dry-run は何も書き込まない" \
    test -f "$M4L_USER_LIBRARY/$target.amxd"
  check "本実行が完走する" \
    "$REPO_ROOT/scripts/install.sh" --yes --device "$target"
  check "  → amxd が配置された" test -f "$M4L_USER_LIBRARY/$target.amxd"
  check "  → Project が配置された" test -d "$M4L_MAX_DEVICES/$target Project"
  check_fails "  → 除外対象の maxsnap は配置されない" \
    test -f "$M4L_MAX_DEVICES/$target Project/data/HPL Processor Ultimate.maxsnap"
  check "amxd がバイト単位で一致する" \
    cmp -s "$REPO_ROOT/devices/$target/$target.amxd" "$M4L_USER_LIBRARY/$target.amxd"
  check "2回目の実行で既存ファイルを退避する" bash -c \
    "'$REPO_ROOT/scripts/install.sh' --yes --device '$target' >/dev/null 2>&1 &&
     ls '$M4L_BACKUP_DIR' | grep -q ."
  check "install 後の status が一致を報告する" bash -c \
    "'$REPO_ROOT/scripts/sync.sh' status '$target' 2>&1 | grep -q 'Project は一致'"

  echo
  echo "== dist の frozen ガード =="
  check_fails "unfrozen な amxd は dist に出せない" \
    "$REPO_ROOT/scripts/sync.sh" dist "$target"
fi

echo
printf '\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
