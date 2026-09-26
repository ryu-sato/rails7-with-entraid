# Research & Design Decisions

## Summary
- **Feature**: `entra-authorization`
- **Discovery Scope**: Extension（グリーンフィールドの Rails 雛形に、`entra-authentication` の上へ載せる小規模な追加）。軽量ディスカバリ（統合点と外部 gem の実挙動の確認）を実施
- **Key Findings**:
  - `omniauth_openid_connect` 0.8.0 の `auth.extra.raw_info` は「userinfo 応答 + デコード済み ID token クレーム」を `merge` したもの（ID token 側が優先）。ID token は code flow では署名検証済み（`verify_id_token!`）
  - `roles` / `groups` / `_claim_names` / `_claim_sources` は userinfo 応答に含まれず、ID token 由来のみ。よってこれらのキーだけを読めば要件 12.3（署名検証済み ID token のクレームのみ）を満たせる
  - cancancan 3.6.1 は `authorize!` / `can?` / `CanCan::AccessDenied` / `check_authorization` を提供。config 5.6.1 は `Settings` と環境別 YAML を提供し、どちらも Ruby 4.0 / Rails 7.2 で解決済み（brief の viability チェックと一致）
  - DB が SQLite / PostgreSQL で未確定（`tech.md`）のため、配列型を DB ネイティブに頼れない。JSON カラムで持つ

## Research Log

### raw_info の中身
- **Context**: ロールの元になるクレームをどこから読むか（要件 2.1, 12.3）
- **Sources Consulted**: `omniauth_openid_connect-0.8.0/lib/omniauth/strategies/openid_connect.rb`（`extra`, `user_info`, `decode_id_token`, `access_token`）
- **Findings**:
  - `extra { { raw_info: user_info.raw_attributes } }`
  - `user_info` は ID token があるとき `access_token.userinfo!.raw_attributes.merge(decoded_id_token_attributes)`
  - `access_token` 取得時に code flow では `verify_id_token!` が呼ばれる（署名・issuer・audience 等の検証）
- **Implications**: `raw_info` 全体を信頼せず、必要な 4 キーのみを読む `Claims` 値オブジェクトを境界に置く。userinfo が同名キーを返す場合は ID token が優先されるため、権限判断のクレームが userinfo で上書きされることはない

### groups の overage
- **Context**: 要件 7.1（overage 検知）
- **Sources Consulted**: brief（Microsoft の仕様の調査結果）
- **Findings**: JWT では 200 グループ超で `groups` が欠落し `_claim_names.groups` と `_claim_sources` が入る。`hasgroups` は implicit flow 用で、code flow では使わない
- **Implications**: 検知条件は「`_claim_names` がハッシュで `groups` キーを持つ」。`groups` の有無より先に判定する

### cancancan
- **Sources Consulted**: `cancancan-3.6.1/lib/cancan/controller_additions.rb`, `ability.rb`, `exceptions.rb`
- **Findings**: `authorize!(action, subject)`、`can?`、`CanCan::AccessDenied`、`check_authorization` が存在。`current_ability` は既定で `Ability.new(current_user)`
- **Implications**: 独自の判定機構は作らない。`Ability` は `user` が `nil` でも動くようにする

### config gem
- **Sources Consulted**: `config-5.6.1/lib/config.rb`, `options.rb`
- **Findings**: `config/settings.yml` + `config/settings/<env>.yml` + `config/settings.local.yml` を読み `Settings` を提供。既定で `use_env: false`。YAML のキー（GUID）は `Config::Options` でシンボルになるため、比較時に文字列化が必要
- **Implications**: マッピングは `to_h.transform_keys(&:to_s)` で正規化し、GUID は小文字化して比較する。ENV 上書きは有効にしない（デプロイ方式が未確定のため、環境別 YAML で足りる）

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A. コールバックにロール処理を直書き | callback コントローラ内で claim 解析 | ファイルが少ない | authentication との責務が混ざる。テストしにくい | 却下 |
| B. PORO の resolver 2 種 + 共通の RoleSync | 方式ごとに「候補ロール名」を返し、共通規則は RoleSync が 1 か所で適用 | 共通規則（既知のみ・重複なし・空なら拒否）が 1 か所。方式追加が容易。テストしやすい | クラスが増える | 採用 |
| C. 方式を継承階層で表現 | 基底クラス + サブクラス | 慣用的 | 実装が 2 つだけで過剰 | 却下 |

## Design Decisions

### Decision: 共通規則を RoleSync に集約し、resolver は候補を返すだけにする
- **Context**: 要件 5.4「方式によらず同一の規則」
- **Alternatives Considered**:
  1. 各 resolver が既知フィルタ・重複排除・空判定まで行う — 規則が 2 か所に複製される
  2. resolver は候補ロール名（または overage）だけ返し、`RoleSync` が共通規則を適用する
- **Selected Approach**: 2
- **Rationale**: 規則の重複を避け、方式間の挙動差が構造上生じない
- **Trade-offs**: resolver は単体では「最終的なロール」を返さない
- **Follow-up**: resolver のテストは候補の抽出だけを対象にする

### Decision: 拒否時は保存済みロールを空にする
- **Context**: 要件 6.3, 7.3, 9.6（拒否後に旧ロールを権限判定に使わない。セッションが残っても無権限）
- **Selected Approach**: 拒否が確定した時点で、既存 `User` のロールを `[]` に更新してから拒否を返す
- **Rationale**: ログイン拒否は新しいログインの不成立であり、他ブラウザに旧セッションが残る場合がある。ロールを空にすれば `Ability` が全操作を拒否する
- **Trade-offs**: 一時的な誤設定（例: マッピングの誤り）でも、その利用者の既存セッションが無権限になる。ただしログイン時にしか反映しない方針と整合する
- **Follow-up**: 初回ログインで拒否された場合、authentication が作成した `User` はロール空のまま残る（許容）

### Decision: ロールは JSON カラムに保存する
- **Context**: DB が SQLite / PostgreSQL で未確定
- **Alternatives Considered**: PostgreSQL 配列型（SQLite 不可）/ 関連テーブル（要件 1.3 の「DB 管理不要」に反する）/ `text` + `serialize`
- **Selected Approach**: `t.json :roles, null: false, default: []`
- **Rationale**: 両 DB で Rails が標準サポートし、追加 gem が不要
- **Follow-up**: SQLite と PostgreSQL の両方でマイグレーションと読み書きをテストで確認する

### Decision: `check_authorization` は有効にしない
- **Context**: 認可漏れの防止と、業務リソースごとの設計が本 spec の対象外であることの両立
- **Selected Approach**: 本 spec ではドメインコントローラが存在しないため強制しない。強制するかは最初のドメイン機能の spec で決める
- **Trade-offs**: 認可の呼び忘れを機械的には検出しない

### Decision: 単純化
- resolver の登録機構やプラグイン化はせず、`case` で 2 方式を選ぶ（実装は 2 つのみで第 3 の方式の要件がない）
- ロール → 権限の定義は `Ability` 内のメソッドに直書きする（ロール数が少ない前提）

## Risks & Mitigations
- omniauth_openid_connect が userinfo を必ず呼ぶ（`userinfo!`）ため、ログインごとに userinfo 呼び出しが発生し、失敗するとログイン自体が失敗する — authentication 側の失敗ハンドリングに委ねる（本 spec の範囲外）
- groups 方式でマッピング漏れがあると全員拒否になる — 起動時に設定を検証し、ロール名が未定義のマッピングは警告する。手順書に事前確認を記載
- ロール名をコードから削除しても DB には旧名が残る — `Ability` は保存値を再度 `Role.known` で絞る
- `User` を authentication が作成するため、拒否された初回ログインでもロール空の `User` が残る — 許容し、design に明記

## References
- [OpenID Connect Core 1.0 - ID Token Validation](https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation)
- Microsoft Learn: Configure groups optional claims / Groups overage claim（brief 記載の調査結果を参照）
- cancancan 3.6.1 / config 5.6.1 のソース（ローカル取得で確認）
