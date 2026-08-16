# リリース手順

デバイスごとに独立してリリースします。片方だけ更新したいときに、
もう片方のバージョンを上げる必要はありません。

## 前提

- リリース対象のデバイスの変更が `main` にマージ済み
- `gh` コマンドが認証済み（`gh auth status`）

## 全体像

バージョン管理・タグ・CHANGELOG は [release-please](https://github.com/googleapis/release-please)
が GitHub Actions 上で自動処理します。人間がやるのは **Max での Freeze** だけです。
Freeze は Max の GUI 操作でしか実行できず、CLI がないためここだけ手作業になります。

```
コミット
  └→ release-please がデバイスごとに Release PR を作る
       └→ PR をマージ
            └→ タグ <device>-v<version> と「ドラフト」Release が作られる
                 └→ Max で Freeze → sync.sh dist → release.sh で添付して公開
```

Release がいったんドラフトで止まるのは、配布物の frozen amxd を後から手で
用意して添付する必要があるためです。中身のない Release が公開されるのを防いでいます。

> **未マージの Release PR について。** 全デバイスの Release PR が
> `.release-please-manifest.json` を共有するため、main が動くたびに未マージの
> Release PR がコンフリクトします。設定で `always-update: true` にしてあるので、
> release-please が毎回 PR を作り直して解消します。それでもコンフリクトが残る
> 場合は、その PR を閉じてブランチを消し、`gh workflow run release-please.yml`
> で作り直させてください（内容は決定論的に再生成されます）。

> **タグについて。** GitHub はドラフト Release では git タグを作りません（公開時に
> 作られます）。一方 release-please は前回リリースのタグを基準に未リリースの
> コミットを数えるため、タグがないと同じコミットを何度も計上して、バージョンだけ
> 上がった Release PR を延々と作り続けます。
>
> これを避けるため、ワークフローを「ドラフト Release 作成 → タグ作成 →
> Release PR 組み立て」の3段階に分けています（`skip-github-pull-request` と
> `skip-github-release` で分割）。素直に1回動かすと Release 作成と PR 組み立てが
> 続けて走ってしまい、あいだにタグを作る隙がないため同じ症状が再発します。
> 公開時 GitHub は既存のタグを再利用するので二重にはなりません。

## コミットの書き方

release-please は **変更したファイルのパス** からどのデバイスのリリースかを判定します。
`devices/panner-for-8ch/` 以下を触ったコミットは `panner-for-8ch` のリリースに含まれます。

型はバージョンの上がり方を決めます。

| 型 | 例 | バージョン |
| --- | --- | --- |
| `fix:` | `fix(panner-for-8ch): 出力 ch のオフセットを修正` | パッチ |
| `feat:` | `feat(8to2ch-hpl): PAD スイッチを追加` | マイナー |
| `feat!:` / `BREAKING CHANGE:` | 既存プリセットが壊れる変更 | メジャー（1.0.0 未満ならマイナー） |
| `chore:` / `docs:` / `refactor:` | ドキュメント修正など | 上がらない（リリースされない） |

スコープ（`(panner-for-8ch)`）は CHANGELOG を読みやすくするためのもので、
判定自体はパスで行われます。`scripts/` や `README.md` だけの変更では
どのデバイスの Release PR も立ちません。

`shared/patchers/` を変更したときは `scripts/shared-sync.sh` を実行してから
コミットしてください。共有パッチャーが各デバイスの Project にコピーされ、
そのコミットが影響デバイス全部のパスを触ることになるので、
release-please が自動的に全影響デバイスをリリース対象にします。
反映漏れは CI が `shared-sync.sh --check` で検出します。

## 順番を守る（重要）

**ソースをコミットしてから Freeze する。** 逆をやると詰みます。

frozen な amxd は `sync.sh pull` で取り込めません。Freeze した状態で
デバイスを編集すると、その変更はリポジトリに入れられないまま手元にだけ存在する
ことになり、Unfreeze するまで先に進めなくなります。

Freeze は「リリースする内容が確定し、PR をマージし終えたあと」の最後の作業です。
編集とコミットが終わるまでは unfrozen のままにしておいてください。

うっかり Freeze したまま編集してしまったら、Unfreeze して保存し、
`sync.sh pull` からやり直せば復帰できます。

## 手順

### 1. Release PR をマージする

`main` に push すると release-please がデバイスごとに Release PR を出します
（`chore(main): release panner-for-8ch 0.2.0` のようなタイトル）。
リリースしたいデバイスの PR **だけ** をマージしてください。

マージすると、そのデバイスのタグとドラフト Release が作られます。

### 2. Max で Freeze する

1. Live でデバイスをトラックに置き、左上の Max ボタンで開く
2. Max のツールバーの **雪の結晶アイコン**（Freeze Device）をクリック
3. `⌘S` で保存

> **Save As は使わないでください。** `dist/` に直接保存すると、Live のトラック上の
> デバイスインスタンスが `dist/` 側のファイルを参照するようになり、以降の編集が
> ソースに反映されなくなります。次の手順のコピー方式なら参照先は User Library の
> ままです。

### 3. dist/ に書き出す

```bash
./scripts/sync.sh dist panner-for-8ch
```

unfrozen のままだと中断します。手順 2 で保存できていない場合はここで気付けます。

### 4. Max で Unfreeze して元に戻す

もう一度**雪の結晶アイコン**をクリックして `⌘S`。

これを忘れると次回の `sync.sh pull` が中断するので、取り返しはつきます。
ただし frozen 状態のまま作業を続けると混乱するので、その場で戻してください。

### 5. 添付して公開する

```bash
./scripts/release.sh panner-for-8ch
```

該当デバイスのドラフト Release を探し、`dist/<name>.amxd` を添付して公開します。
中身を確認してから公開したい場合は `--keep-draft` を付けると添付だけで止まります。

### 6. 状態を確認する

```bash
./scripts/sync.sh status
```

`amxd は一致` と出れば、リポジトリのソースと手元の実体が揃っています。
`Live 側は frozen 状態です` と出たら手順 4 を忘れています。

## 複数デバイスをまとめてリリースする

手順 1 でそれぞれの Release PR をマージし、手順 2〜5 をデバイスごとに繰り返します。
`sync.sh dist` は引数なしで全デバイスを対象にできますが、Freeze は1つずつ
手作業なので、1デバイスずつ通す方が間違いが少ないです。

## 公開済み Release に差し替える

```bash
gh release upload <tag> dist/<name>.amxd --clobber
```
