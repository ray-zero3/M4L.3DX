# M4L.3DX

Novo Notes 3DX を使った Max for Live デバイス集。8ch のイマーシブ環境への
パンニングと、それをヘッドホンで確認するためのバイノーラル折り返しを1組で扱う。

| デバイス | 役割 | 信号経路 |
| --- | --- | --- |
| `panner-for-8ch` | ステレオを 8ch のスピーカー配置へ定位させる | `plugin~` → `vst~ 2 8 3DX` → `plugout~ 1 2`（モニター）+ `plugout~ 3-10`（8ch フィード） |
| `8to2ch-hpl` | 8ch を HPL バイノーラルでステレオに畳み込む | `plugin~ 1-8` → `mc.*` → `vst~ 8 2 3DX` → `plugout~` |

送り先の選択には Ableton 公式デバイス **Audio Sends** のルーティング UI を流用している（後述）。

## 必要なもの

- **Novo Notes 3DX（VST3・有償）— 必須**。<https://novo-notes.com/3dx>
  **これらのデバイスを使うには 3DX の購入とインストールが必要です。**
  両デバイスとも定位処理・バイノーラル処理を 3DX に任せているため、
  未インストールだとデバイスは読み込まれても音を出しません。
- **Ableton Live 12 Suite**（または Max for Live を含むエディション）
- **Max 9.1 以降** — デバイスは Max 9.1.4 で保存されている。Live 11 / Max 8 では開けない。

## 入れ方

### 使うだけの人

1. [Releases](../../releases) から使いたいデバイスの `.amxd` をダウンロード
2. Live のブラウザにドラッグする、または
   `~/Music/Ableton/User Library/Presets/Audio Effects/Max Audio Effect/` に置く

配布している `.amxd` は **frozen**（依存ファイルを内包した状態）なので、
このファイル1つで完結します。ターミナルも git も不要です。

デバイスは個別にバージョン管理されています。タグは `panner-for-8ch-v1.2.0` のように
デバイス名で分かれていて、片方だけ更新されることがあります。

### 中身をいじる人 / 別の Mac に開発環境を作る人

```bash
git clone https://github.com/ray-zero3/M4L.3DX.git
cd M4L.3DX
./scripts/install.sh
```

編集できる **unfrozen** の状態で Live と Max の所定の場所に配置されます。
既存の同名ファイルはバックアップしてから上書きします。

配置先は自動検出しますが、環境が違う場合は上書きできます。

```bash
M4L_USER_LIBRARY="/path/to/Max Audio Effect" \
M4L_MAX_DEVICES="/path/to/Max for Live Devices" \
  ./scripts/install.sh
```

何をするか先に見たいときは `./scripts/install.sh --dry-run`。

## リポジトリの構成

```
devices/<name>/
  device.conf              このデバイスのマニフェスト（依存・除外設定）
  <name>.amxd              デバイス本体（unfrozen。これがソース）
  <name> Project/          Max が依存を解決するためのプロジェクトフォルダ
    patchers/  data/
shared/patchers/           複数デバイスで使う自作パッチャーの原本
scripts/                   同期・導入・リリース用のスクリプト
dist/                      Freeze 済み amxd の出力先（追跡しない）
```

`devices/` にある unfrozen な amxd が唯一のソースです。frozen 版は配布物であって
ソースではないので、リポジトリには入れず GitHub Releases だけで配ります。

## 開発の流れ

Max / Live 側の実ファイルとリポジトリは別の場所にあるので、スクリプトで往復させます。

```bash
./scripts/sync.sh status   # 両者の差分を確認
./scripts/sync.sh pull     # Max / Live → repo（編集をリポジトリに取り込む）
./scripts/sync.sh push     # repo → Max / Live（リポジトリの内容を反映）
./scripts/sync.sh paths    # 解決された配置先を表示
```

`pull` は `--delete` 付きで実体に完全に合わせます。`push` は事故防止のため
`--delete` を付けず、追加と更新だけ行います。

Max で編集 → `pull` → コミット、が基本サイクルです。

### frozen をソースに混ぜないための仕組み

frozen な amxd は依存ファイルを全部内包するのでサイズが倍増し、差分が読めなくなります。
これをソースにコミットすると履歴が台無しになるため、多重にガードしています。

- `pull` は frozen な amxd を見つけたら中断する
- `dist` は unfrozen な amxd を見つけたら中断する
- CI が `devices/` 配下に frozen な amxd がないか毎回チェックする

判定は amxd の JSON に `"dependency_cache"` キーがあるかどうかで行っています。

### `.gitattributes` について

`.amxd` は「32byte のバイナリヘッダ + JSON 本文」という構造で、ヘッダに本文の
バイト長が記録されています。git に改行コードを変換されると長さがズレてファイルが
壊れるため、`.gitattributes` で `-text`（変換禁止）を指定しています。同時に `diff`
を指定しているので、`git diff` ではテキストとして中身の差分が読めます。

**この設定を外さないでください。**

## Ableton 公式デバイス由来のファイルについて

両デバイスは、Live 12 に同梱されている公式 Max for Live デバイス **Audio Sends** の
パッチャーを利用しています。

| ファイル | 出所 |
| --- | --- |
| `SendsRouting.maxpat` | Audio Sends |
| `ReceivesRouting.maxpat` | Audio Sends の `SendsRouting.maxpat` をリネームしたバイト単位で同一のコピー |
| `RoutingObjects2.maxpat` | Audio Sends |

これらは Ableton のコンテンツなので、**このリポジトリでは再配布せず追跡対象から
外しています**。`scripts/install.sh` があなたの Mac の Live から取得します。
もし取得元が見つからない場合は、Live で Audio Sends デバイスを一度 Max で開けば
`~/Documents/Max 9/Max for Live Devices/Audio Sends Project/` が作られます。

> Releases で配布している frozen amxd には、Freeze の仕組み上これらのパッチャーが
> 埋め込まれています。利用には Live Suite（Max for Live 付き）が前提です。

## デバイスを追加する

1. `devices/<name>/device.conf` を作る（既存のものをコピーするのが早い）
2. `release-please-config.json` の `packages` と
   `.release-please-manifest.json` に `devices/<name>` を追加する
3. `./scripts/sync.sh pull <name>` で Max / Live から取り込む
4. `feat(<name>): ...` でコミットする

## リリース

[RELEASING.md](RELEASING.md) を参照。デバイスごとに独立してリリースできます。

## 検証

```bash
./scripts/test.sh
```

一時ディレクトリに隔離した砂場で動かすので、あなたの Live / Max フォルダには
一切触れません。
