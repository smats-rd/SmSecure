# Domainモデル一覧

作成日：2026-11-14

## 概要

Domainは、収集データをどう解釈し、履歴をどう比較・確認するかという業務上の概念と判定ルールを指す。Autorunscの起動、CSV解析、DBアクセス、画面表示そのものはDomainに含めない。

| 概念 | 1つが表すもの | 主な責務 | 現在の実装状況 |
|---|---|---|---|
| 収集試行（Collection Run） | 収集処理を1回実行した記録 | 開始・終了、成功・失敗・タイムアウト・解析失敗・中断を区別する | `CollectionRun`と状態・失敗コードの型を実装。CLI・DB連携は未実装。 |
| スナップショット（Snapshot） | 成功した1回の収集結果と比較条件 | 収集試行、作成日時、引数保存方針を持ち、互換な過去データから比較基準を選ぶ | `Snapshot`型、`SnapshotDescriptor`と比較基準選択処理を実装。永続化・DB連携は未実装。 |
| 収集範囲（Scope） | スナップショット内の1つの対象範囲と、要求有無・取得状態・理由コード | 完全・部分・失敗・未試行・不明を区別し、両スナップショットで要求かつ完全取得の共通範囲を選ぶ | Snapshotの型と共通範囲の判定を実装。実際の収集結果との接続は未実装。 |
| 項目（Item） | 検証済み識別ルールで履歴を通じて追跡する論理的な自動起動項目 | 不透明な項目IDで観測から参照される。ID生成・識別はカテゴリ検証後に定める | `Item`と`ItemId`の不透明な型を実装。識別・DB連携は未実装。 |
| 観測（Observation） | 1スナップショット内の1つの収集結果 | 項目との対応状態、取得値、値が不明な理由、引数の保存状態を保持する | 型と引数保存・比較用変換処理を実装。収集・永続化は未実装。 |
| 比較結果（Comparison） | 対応する2観測の差分判定 | フィールド別比較、変更・変更なし・一部未比較・比較不能を判定する | 比較処理を実装。存在差分の根拠や収集カバレッジの統合は未実装。 |
| 確認記録（Review） | 1つの観測に対する利用者の確認 | 確認日時と任意メモを記録し、観測に結び付ける | 型のみ実装。記録・再確認処理は未実装。 |

## 実装済みコードとの対応

- [observation.ts](../src/domain/observation.ts): 観測値、利用不可理由、引数の取得・保存状態、`Observation`、`Review`。
- [comparison.ts](../src/domain/comparison.ts): フィールド比較、比較範囲の要約、主状態の判定。
- [snapshot.ts](../src/domain/snapshot.ts): スナップショット互換性、範囲カバレッジ、比較基準の選択。
- [collectionRun.ts](../src/domain/collectionRun.ts): 収集試行の状態と安全な失敗コード。
- [item.ts](../src/domain/item.ts): 不透明な項目IDと項目参照。
- [autorunscCsv.ts](../src/collector/autorunscCsv.ts): Domainではなく、Autorunsc出力を読み込むCollector層。

「実装済み」はDomain型・純粋な判定処理の範囲を指す。CLI、DB、収集アダプター、画面と結合した機能が完成したことを意味しない。追加・削除の確定には、項目識別と収集範囲の検証が別途必要。

## DomainとDBの対応

| Domain | DB | 対応方法 |
|---|---|---|
| `CollectionRun` | `collection_runs` | ID、開始・終了日時、状態、失敗コード、収集条件を保存する。 |
| `Snapshot` | `snapshots` | 成功した試行ID、作成日時、互換性条件、引数保存方針を保存する。 |
| `SnapshotScope` | `snapshot_scopes` | スナップショット内のscope IDごとに、要求有無、取得状態、理由コードを1行で保存する。 |
| `Item` | `items` | 不透明なIDで参照する。自然キーや一意性の意味は識別ルール検証後に決める。 |
| `Observation` | `observations` | スナップショット内の観測値を保存し、解決済みなら`item_id`で項目を参照する。 |
| `Review` | `reviews` | 1観測に最大1件の確認日時・メモを保存する。 |
| 比較結果 | なし | 保存済みスナップショットと観測から導出し、独立したDBエンティティにはしない。 |

関連資料：[実装計画](./implementation-plan.md)、[DB設計](./database-design.md)、[機能一覧](./feature-list.md)。
