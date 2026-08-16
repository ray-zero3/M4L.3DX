#!/usr/bin/env bash
#
# 開発者用。リポジトリと Max / Live の実ファイルを行き来させる。
#
#   sync.sh pull    Max / Live → repo   （実体をリポジトリに取り込む。--delete あり）
#   sync.sh push    repo → Max / Live   （--delete なし。事故防止のため消さない）
#   sync.sh status  両方向をドライランで表示
#   sync.sh vendor  Ableton 公式デバイスから vendor パッチャーを取得
#   sync.sh dist    frozen amxd を dist/ に書き出す
#   sync.sh paths   解決された配置先パスを表示
#
# 対象を絞るときは末尾にデバイス名を渡す:  sync.sh pull panner-for-8ch

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 引数で指定がなければ全デバイスを TARGETS 配列に入れる。
#
# コマンド置換（$(...)）で呼ぶとサブシェルになり、die の exit が呼び出し元に
# 伝わらず不正なデバイス名を素通ししてしまう。必ず直接呼ぶこと。
resolve_targets() {
  TARGETS=()
  local name
  if [ "$#" -gt 0 ]; then
    for name in "$@"; do
      [ -f "$REPO_ROOT/devices/$name/device.conf" ] || die "そんなデバイスはありません: $name"
      TARGETS+=("$name")
    done
  else
    while IFS= read -r name; do TARGETS+=("$name"); done < <(list_devices)
  fi
  [ "${#TARGETS[@]}" -gt 0 ] || die "devices/ にデバイスがありません"
}

# ---------------------------------------------------------------- pull
cmd_pull() {
  require_paths
  resolve_targets "$@"
  for name in "${TARGETS[@]}"; do
    load_device "$name"
    build_excludes

    [ -f "$LIVE_AMXD" ] || die "$LIVE_AMXD がありません"
    [ -d "$LIVE_PROJECT" ] || die "$LIVE_PROJECT がありません"
    assert_unfrozen "$LIVE_AMXD"

    mkdir -p "$DEVICE_PROJECT"
    rsync -a "$LIVE_AMXD" "$DEVICE_AMXD"
    rsync -a --delete "${EXCLUDES[@]}" "$LIVE_PROJECT/" "$DEVICE_PROJECT/"
    ok "pull $name"
  done
}

# ---------------------------------------------------------------- push
cmd_push() {
  require_paths
  resolve_targets "$@"
  for name in "${TARGETS[@]}"; do
    load_device "$name"
    build_excludes

    [ -f "$DEVICE_AMXD" ] || die "$DEVICE_AMXD がありません。先に pull してください。"
    assert_unfrozen "$DEVICE_AMXD"

    mkdir -p "$LIVE_PROJECT"
    rsync -a "$DEVICE_AMXD" "$LIVE_AMXD"
    rsync -a "${EXCLUDES[@]}" "$DEVICE_PROJECT/" "$LIVE_PROJECT/"
    ok "push $name"
  done
}

# -------------------------------------------------------------- status
cmd_status() {
  require_paths
  show_paths
  resolve_targets "$@"
  local name
  for name in "${TARGETS[@]}"; do
    load_device "$name"
    build_excludes
    printf '\n' >&2
    info "$name"

    if [ ! -f "$LIVE_AMXD" ]; then
      warn "  Live 側に amxd がありません"
    elif [ ! -f "$DEVICE_AMXD" ]; then
      warn "  repo 側に amxd がありません（未 pull）"
    elif cmp -s "$LIVE_AMXD" "$DEVICE_AMXD"; then
      ok "  amxd は一致"
    else
      warn "  amxd に差分あり"
      is_frozen "$LIVE_AMXD" && warn "  Live 側は frozen 状態です（Unfreeze を忘れていませんか）"
    fi

    if [ -d "$LIVE_PROJECT" ] && [ -d "$DEVICE_PROJECT" ]; then
      local diff
      # --checksum で中身だけを比較する。更新時刻の差で騒がないようにするため。
      diff="$(rsync -rin --checksum --delete "${EXCLUDES[@]}" "$LIVE_PROJECT/" "$DEVICE_PROJECT/" || true)"
      if [ -z "$diff" ]; then
        ok "  Project は一致"
      else
        warn "  Project に差分あり（Live 側 → repo 側 で pull した場合の変更）:"
        printf '%s\n' "$diff" | sed 's/^/       /' >&2
      fi
    else
      warn "  Project フォルダが片側にありません"
    fi
  done
}

# -------------------------------------------------------------- vendor
# Ableton 公式デバイスの Project フォルダから、再配布しないパッチャーを取得する。
cmd_vendor() {
  require_paths
  resolve_targets "$@"
  local name rec src dst want got missing=0
  for name in "${TARGETS[@]}"; do
    load_device "$name"
    for rec in ${VENDOR[@]+"${VENDOR[@]}"}; do
      src="$MAX_DEVICES/$(field "$rec" 1)"
      dst="$DEVICE_PROJECT/$(field "$rec" 2)"
      want="$(field "$rec" 3)"

      if [ ! -f "$src" ]; then
        warn "$name: 取得元がありません → $(field "$rec" 1)"
        missing=1
        continue
      fi

      got="$(sha1_of "$src")"
      if [ "$got" != "$want" ]; then
        warn "$name: $(basename "$src") の sha1 が想定と違います
       expected $want
       actual   $got
       Live のバージョン差かもしれません。動作しない場合はここを疑ってください。"
      fi

      mkdir -p "$(dirname "$dst")"
      # -p で更新時刻を維持する。落とすと status が中身の同じ vendor ファイルを
      # 毎回「差分あり」と報告してしまう。
      cp -p "$src" "$dst"
      ok "vendor $name ← $(field "$rec" 2)"
    done
  done

  if [ "$missing" -eq 1 ]; then
    die "vendor ファイルを取得できませんでした。

  これらは Ableton 公式デバイス「Audio Sends」に含まれるパッチャーです。
  ライセンス上このリポジトリでは再配布していないので、手元の Live から取り出します。

    1. Live で任意のオーディオトラックに Audio Sends デバイスを追加する
    2. デバイス左上の Max ボタン（編集）を押して Max で開く
    3. Max が
         $MAX_DEVICES/Audio Sends Project/
       を作るので、Max を閉じる
    4. このコマンドを再実行する"
  fi
}

# ---------------------------------------------------------------- dist
# Freeze 済みの amxd を dist/ に書き出す。Freeze は Max の GUI 操作なので手動。
cmd_dist() {
  require_paths
  mkdir -p "$REPO_ROOT/dist"
  resolve_targets "$@"
  local name
  for name in "${TARGETS[@]}"; do
    load_device "$name"
    [ -f "$LIVE_AMXD" ] || die "$LIVE_AMXD がありません"
    assert_frozen "$LIVE_AMXD"
    cp "$LIVE_AMXD" "$REPO_ROOT/dist/$name.amxd"
    ok "dist $name.amxd  ($(du -h "$REPO_ROOT/dist/$name.amxd" | awk '{print $1}'))"
  done
  info "Max に戻って雪の結晶アイコンで Unfreeze し、保存してください。"
}

# --------------------------------------------------------------- paths
cmd_paths() {
  show_paths
  local name
  for name in $(list_devices); do
    load_device "$name"
    printf '  %-18s %s\n' "$name" "$DESCRIPTION" >&2
  done
}

# ---------------------------------------------------------------- main
cmd="${1:-}"
[ "$#" -gt 0 ] && shift || true
case "$cmd" in
  pull)   cmd_pull   "$@" ;;
  push)   cmd_push   "$@" ;;
  status) cmd_status "$@" ;;
  vendor) cmd_vendor "$@" ;;
  dist)   cmd_dist   "$@" ;;
  paths)  cmd_paths  "$@" ;;
  *)      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
