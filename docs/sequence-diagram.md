# 画面・DB・動作契機のシーケンス

作成日：2026-11-14

この図は実装目標を示す。CLI、DB、Web画面はいずれも未実装で、テーブル名と状態遷移は設計案である。Webはログインなしでループバックから利用し、収集はWeb画面から起動しない。

## 1. 収集とスナップショット保存

**動作契機:** 利用者がCLIで収集コマンドを実行する。履歴画面や比較画面を開いただけでは収集しない。

```mermaid
sequenceDiagram
    actor User as 利用者
    participant CLI as 収集CLI
    participant DB as PostgreSQL
    participant AR as Autorunsc
    participant Parser as 解析・Domain

    User->>CLI: 収集コマンドを実行
    CLI->>DB: 専用接続を開く
    CLI->>DB: セッションアドバイザリロック取得
    alt ロックを取得できない
        DB-->>CLI: 取得失敗
        CLI-->>User: 競合を明示して終了
    else ロック取得
        DB-->>CLI: ロック保持
        CLI->>DB: 残存する実行中試行を中断にする
        CLI->>DB: collection_runsを実行中で記録（started_at）
        DB-->>CLI: 試行ID
        CLI->>AR: 許可した引数で実行（タイムアウト付き）
        AR-->>CLI: 終了状態と出力（メモリ内）
        CLI->>Parser: 出力を解析し範囲・観測を判定
        alt 実行・解析に失敗
            CLI->>DB: collection_runsを失敗状態に更新（finished_at、安全なエラーコード）
            CLI-->>User: 失敗と試行IDを表示
        else 収集・解析に成功
            CLI->>DB: 同じ接続で保存トランザクション開始
            CLI->>DB: snapshotsを試行IDに関連付けて作成（created_at）
            CLI->>DB: snapshot_scopes、items、observationsを保存
            CLI->>DB: collection_runsを成功状態に更新（finished_at）
            CLI->>DB: コミット
            DB-->>CLI: 保存結果
            CLI-->>User: 完了とスナップショットIDを表示
        end
    end
```

ロック保持接続を失った場合は子プロセスを停止し、成功として報告しない。保存失敗時はスナップショットを成功扱いせず、可能なら安全な失敗状態を記録する。生出力をログや一時ファイルに保存しない。

## 2. 履歴・比較画面

**動作契機:** 利用者が履歴画面を開く、または比較対象を選ぶ。画面表示ではDBを読み取るだけで、収集は起動しない。

```mermaid
sequenceDiagram
    actor User as 利用者
    participant Browser as ブラウザー
    participant Web as ローカルWeb
    participant DB as PostgreSQL
    participant Domain as 基準選択・比較Domain

    User->>Browser: 履歴画面を開く
    Browser->>Web: GET /history（ログインなし）
    Web->>Web: ループバック、Host/Originを検査
    Web->>DB: 試行・成功スナップショット・範囲を検索
    DB-->>Web: 履歴と状態
    Web-->>Browser: 履歴一覧を返す
    Browser-->>User: スナップショット作成日時、試行状態・日時、範囲を表示

    User->>Browser: 比較対象を選択
    Browser->>Web: GET /compare/{snapshotId}
    Web->>DB: 対象と候補履歴の範囲・条件・観測を検索
    DB-->>Web: 比較に必要な保存データ
    Web->>Domain: 互換性を確認し比較基準を選択
    Domain->>Domain: 対応付け・存在状態・内容差分を判定
    Domain-->>Web: 結果と未比較理由
    Web-->>Browser: 比較結果を返す
    Browser-->>User: 差分、判定不能、未取得範囲を表示
```

比較基準がない場合は初回観測、互換性や存在の根拠がない場合は比較不能とする。異なる範囲を古い履歴で補わない。カテゴリ別の追加・削除表示は検証済み範囲に限る。

## 3. 項目詳細・確認記録

**動作契機:** 利用者が比較結果から項目を開く。確認記録は画面上の明示的な操作でのみ作成する。

```mermaid
sequenceDiagram
    actor User as 利用者
    participant Browser as ブラウザー
    participant Web as ローカルWeb
    participant DB as PostgreSQL

    User->>Browser: 項目詳細を開く
    Browser->>Web: GET /observations/{id}
    Web->>Web: ループバック、Host/Originを検査
    Web->>DB: 観測、対応項目、確認記録を検索
    DB-->>Web: 保存済みデータ
    Web-->>Browser: 詳細を返す
    Browser-->>User: 値、比較状態、未比較理由、確認状態を表示

    User->>Browser: 確認と任意メモを送信
    Browser->>Web: POST /observations/{id}/review（CSRFトークン付き）
    Web->>Web: Host/Origin、CSRF、入力を検査
    Web->>DB: reviewsを観測ID一意で作成
    alt 既に確認記録がある
        DB-->>Web: 既存記録
    else 新規記録
        DB-->>Web: 作成した記録
    end
    Web-->>Browser: 確認結果を返す（既存記録は上書きしない）
    Browser-->>User: 保存結果を表示
```

## DB上の関係

- `collection_runs`は`started_at`、`finished_at`と試行状態を保持する。成功時に作られる`snapshots`は試行IDと`created_at`を保持する。
- `snapshots`は複数の`snapshot_scopes`と`observations`を持つ。
- `items`は検証済み識別子を持つ項目で、`observations`は項目に対応付けられない場合も理由付きで保存できる。
- `reviews`は一つの`observation`を参照し、観測IDにつき最大1件とする。
- 閲覧・比較は読み取り、確認操作は`reviews`の作成のみ。観測データの更新・削除は行わない。

関連資料: [機能一覧](./feature-list.md)、[実装計画](./implementation-plan.md)、[技術検証メモ](./technical-validation.md)。
