# Implementation Plan

> 前提: `entra-authentication` の実装（`users` テーブル、サインイン可否ゲート、callback、失敗ハンドリング）。実装済みの成果物を利用する。接続は authentication のコードを変更せず、ゲートへのアダプタ登録で行う。
> ロール名（`admin` / `member`）と初期の権限定義は仮置きで、ドメイン機能の spec で確定する（design.md「Open Questions / Risks」）。

- [ ] 1. Foundation: 依存 gem・設定・ロール定義・データ基盤
- [x] 1.1 cancancan と config の導入、設定ファイル構成の用意
  - cancancan 3.6 系と config 5.6 系を追加し、config の初期化と設定ファイル（共通・環境別・ローカル上書き）の構成を用意する
  - 共通設定にはグループ → ロールの対応表（既定は空）だけを置き、方式の指定（role_source）には既定値を置かない
  - ローカル上書きの設定ファイルをバージョン管理の対象外にする
  - 導入後に Rails コンソールから設定値を読める。ローカル上書きファイルが Git の管理対象にならない
  - _Requirements: 4.1_

- [x] 1.2 ロール定義の作成
  - 有効なロール名の一覧をコードで定義し（仮に `admin`, `member`）、未定義名の除去・重複排除・定義順での返却を 1 か所で行えるようにする
  - 文字列以外の要素は無視する
  - 単体テストで、未定義名のみ・重複・非文字列・空配列の各入力に対する結果が確認できる
  - _Boundary: Role_
  - _Requirements: 1.1, 1.3, 2.3, 2.4_

- [x] 1.3 利用者テーブルへのロール配列カラム追加
  - `users` にロール名の配列を保持する JSON カラムを、null 不可・既定は空配列で追加する（別マイグレーション）
  - `entra-authentication` の `users` 作成マイグレーションより後に実行される
  - 既存行が空配列で導入され、SQLite で読み書きできる。PostgreSQL（Dev Container）でも同じマイグレーションが通り、既定値と読み書きが動く
  - _Requirements: 1.2, 1.4_

- [x] 1.4 方式・マッピング設定の起動時検証と環境別の方式指定
  - アプリ起動完了後（アプリの定数が使える時点）に、方式の指定が未指定・未対応値なら分かるエラーで起動を止める
  - グループ方式のとき、対応表が未定義のロール名を指すものや空の対応表に警告を出す
  - 開発・テスト・本番の各環境設定で方式を明示する（テスト環境も明示する）
  - 方式未指定・未知の値で起動が失敗し、正しい値では起動できる。未定義ロールを指す対応表で警告が出る
  - _Depends: 1.1, 1.2_
  - _Requirements: 4.4, 5.2, 5.3_

- [ ] 2. Core: クレーム解決・権限定義・権限なし応答
- [x] 2.1 クレームの取り出しと結果型の定義
  - ID token 由来の `roles` / `groups` / `_claim_names` / `_claim_sources` の 4 キーだけを型検査して取り出す値オブジェクトを作る。型が想定と異なる値は空として扱う
  - `groups` の欠落と `_claim_names` に groups があることから overage を判定できる
  - 候補ロール・保存済みロール・拒否（理由: ロールなし / overage）を区別する結果型を用意する
  - クレームの内容を文字列表示・ログ出力に出さない（内容が伏せられる）
  - 単体テストで、4 キー以外が保持されない、型不正が空になる、overage 判定、表示に内容が出ないことが確認できる。実際の OmniAuth のハッシュ形式（文字列キー）でも動く
  - _Boundary: Authorization Claims, Authorization Result_
  - _Requirements: 7.1, 8.2, 12.1, 12.3_

- [x] 2.2 roles クレーム方式のロール抽出
  - roles クレームの値をそのまま候補ロール名として返す。groups の内容は参照しない
  - roles なし・値が空の場合は空の候補を返す
  - 単体テストで、通常値・roles なし・未定義値のみ・groups が同時にあっても無視されることが確認できる
  - _Boundary: RolesClaimResolver_
  - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 2.3 (P) groups クレーム方式のロール抽出と overage 検知
  - グループ Object ID とロール名の対応表から、groups に含まれるグループに対応する候補ロール名を返す。対応表にないグループは無視する。GUID は大文字小文字を区別せず照合する
  - overage を groups の有無より先に判定し、外部 API を呼ばずに「overage による拒否」を返す
  - groups も overage もなければ空の候補を返す。roles クレームは参照しない
  - 単体テストで、対応表の一致・不一致、GUID の大文字小文字差、overage の優先、roles の無視、通信が発生しないことが確認できる
  - _Boundary: GroupsClaimResolver_
  - _Depends: 2.1_
  - _Requirements: 4.2, 4.3, 4.5, 4.6, 7.1, 7.4_

- [x] 2.4 (P) ロールごとの権限定義
  - ロールごとの権限を 1 か所（ロール別のメソッド）で定義し、複数ロールは全て適用して和集合にする。初期のドメインリソースがないため定義は最小限の仮置きとする
  - 利用者が未指定またはロールなしのときは何も許可しない。保存値は再度定義済みロールで絞ってから適用し、コードから消えたロールは効かない
  - 単体テストで、単一ロール・複数ロールの和集合・ロールなし・未指定利用者・DB に残った未定義ロールの各ケースの可否が確認できる
  - _Boundary: Ability_
  - _Depends: 1.2, 1.3_
  - _Requirements: 9.1, 9.2, 9.6, 9.7_

- [x] 2.5 (P) 拒否理由と権限なしのメッセージ文言
  - ロールなし・overage・権限なしの各文言を英語・日本語で用意する。理由ごとに別の文言とし、クレームの生の内容やグループ Object ID は含めない
  - 全ての理由について両言語の文言が存在することがテストで確認でき、文言に動的な値が含まれない
  - _Boundary: Rejection messages_
  - _Requirements: 6.2, 7.2, 8.1, 8.2_

- [x] 2.6 権限なし時の共通応答
  - 権限判定で拒否されたとき、HTML には権限なし画面（文言はタスク 2.5 で用意）を 403 で、それ以外の形式は本文なしの 403 で返す共通処理を、アプリ全体のコントローラの基底に組み込む
  - 権限なし画面と応答にはロール名・権限定義・例外メッセージを含めない
  - 未ログインの場合は 403 ではなく認証のログイン導線に委ねる
  - 拒否されたコントローラのテストで 403 と画面内容（内部情報なし）が確認でき、副作用が起きない（操作の前で拒否される）。未ログインのケースはタスク 5.2 で確認する
  - _Boundary: AuthorizationHandling_
  - _Depends: 2.5_
  - _Requirements: 9.3, 9.5, 10.1, 10.2, 10.3, 10.4_

- [ ] 3. RoleSync: ロールの導出・共通規則・保存と拒否
- [x] 3.1 ロール同期の実装
  - 設定された方式の抽出結果に、全方式共通の規則（定義済みロールのみ・重複なし・空なら拒否）を適用する
  - 成功時は利用者のロールを導出結果で置き換える（差分ではなく全置換）。ロールの書き込みはここだけで行う
  - ロールなし・overage の拒否時は、保存済みの利用者のロールを空にし、拒否の理由と利用者 ID だけを警告ログに記録する（クレームの内容は出さない）
  - 単体・統合テストで、roles 方式と groups 方式の双方について、置換、全取り消し後の拒否、旧ロールの消去、未定義ロールのみの拒否が同じ結果になり、roles 方式では overage 相当のクレームがあっても拒否されない。ログに理由と ID だけが出る
  - _Boundary: RoleSync_
  - _Depends: 1.2, 1.3, 1.4, 2.1, 2.2, 2.3_
  - _Requirements: 2.1, 2.2, 2.5, 5.1, 5.4, 6.1, 6.3, 6.4, 7.1, 7.3, 7.5, 8.4, 12.1, 12.2_

- [ ] 4. Integration: ログイン処理への接続
- [x] 4.1 サインイン可否ゲートへのアダプタ作成と登録
  - authentication のサインイン可否ゲートに登録する薄いアダプタを作る。ロール同期の結果を受理・拒否の判定に変換し、拒否では理由に対応する固定文言を付ける
  - アプリの初期化処理でゲートに登録する。ゲートの評価時に初めてロール同期を参照する（リロード対象の定数を起動時に参照しない）。authentication のコードは変更しない
  - テストはゲートが各テストの前後でリセットされるため、必要なテストで登録し直す
  - ロールを持つ利用者はログインでき、`current_user` のロールが最新になる。ロールなし・overage の利用者はログイン画面に戻り、理由の文言が表示され、ログイン済みにならない
  - _Boundary: SignInGateAdapter_
  - _Depends: 2.5, 3.1_
  - _Requirements: 2.1, 6.1, 6.2, 7.1, 7.2, 8.1, 8.3_

- [ ] 5. Validation: 統合テストと運用文書
- [x] 5.1 ログイン拒否フローの統合テスト
  - OmniAuth のテストモードで、ロールあり・ロールなし・全取り消し後の再ログイン・overage・roles 方式での overage 相当クレームの各ケースを実際のログイン経路で確認する
  - 拒否後に旧セッションが残っても権限がなく、拒否の警告ログが出る
  - ロールなしと overage で表示される文言が区別でき、内部情報を含まない。テストが全て通る
  - _Depends: 4.1_
  - _Requirements: 2.2, 6.1, 6.2, 6.3, 6.4, 7.1, 7.2, 7.3, 7.5, 8.1, 8.2, 8.3, 8.4_

- [x] 5.2 権限判定の統合テスト
  - テスト専用のダミーコントローラとルートで、コントローラの権限判定・ビューでの出し分け・ロールなしセッションの全拒否・未ログインのログイン導線への誘導を確認する
  - ダミーはテストコードの中だけに置き、本番のルーティングに追加しない
  - 許可されたロールでは操作でき、許可されないロールでは 403 と副作用なし、未ログインではログイン画面へ遷移する。テストが全て通る
  - _Depends: 2.4, 2.6, 4.1_
  - _Requirements: 9.2, 9.3, 9.4, 9.5, 9.6, 10.1, 10.2, 10.4_

- [x] 5.3 (P) Entra ID 側設定手順と方式選択の文書
  - roles 方式（App Roles の定義・グループの割り当て・割り当て必須・ロール値とコード上のロール名の一致・階層が反映されないこと）と groups 方式（セキュリティグループの出力設定・GUID の対応表への登録・overage の上限と事前確認方法）の手順を文書化する
  - テナントの契約種別に基づく方式選択の基準と、ロール変更がログイン時にのみ反映されること・反映遅延の上限（authentication のセッション絶対上限）を記載する
  - 文書が両方式の前提、制約、選択基準、反映タイミングを網羅し、設定キー名が実装と一致している
  - _Boundary: Setup guide_
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

## Implementation Notes
- 実行環境: authentication の記録どおり `DATABASE_URL` は到達不能な PostgreSQL を指すため、worktree のセッションでは `unset DATABASE_URL` してから `bin/rails test` / `bin/rubocop` / `bin/rails zeitwerk:check` を実行する（このセッションでは `env -u` が拒否される）。実 Entra ID への通信は行わない（テストは authentication の WebMock + `OidcProviderStub` のみ）
- 1.3: `users.roles` は SQLite で検証済み（既定値・読み書き・NOT NULL・redo）。PostgreSQL は `pg` が Gemfile になく `DATABASE_URL` も到達不能なため未検証（DB の選定は本 spec の対象外）。JSON カラムは PostgreSQL でも標準サポートのため、DB を PostgreSQL に決めたときに同じマイグレーションでテストを実行して確認する
- 接続方式: callback には触れず、authentication の `EntraAuth::SignInGate.register` にアダプタを登録する（design.md 更新済み）。ゲートのテストは各テストの前後で `reset!` されるため、アダプタを使うテストは setup で再登録する
- config gem の `Config` はトップレベルの定数で、authentication の `EntraAuth::Config` は名前空間内のため衝突しない（1.1 で全テスト通過を確認）
- 1.3 の影響: authentication の `test/models/user_test.rb` と `test/db/users_table_test.rb` は `users` の列を完全一致で検証しているため、`roles` の追加に合わせて期待値に `roles` を加えた（資格情報らしい列を拒む意図は維持）。以後、コミット前に必ず全テストの結果を確認する（1.3・1.4 のコミットは全テスト未確認で行い、この修正で解消した）
- 4.1: 接続は `config/initializers/authorization.rb` の `after_initialize` で `EntraAuth::SignInGate.register`（呼び出し時に `Authorization::SignInGateAdapter` を参照する lambda。リロード対応）。authentication のコードは未変更。テストは `test/support/authorization_gate.rb`（起動時に登録されたゲートを support 読み込み時に控えておき、`register_authorization_gate` で戻す。`with_role_source` で方式を一時的に切り替える）、`oidc_sign_in_flow.rb`（実際の Strategy を WebMock のスタブに通す。ID token に `roles` / `groups` / `_claim_names` を入れられる。setup でゲートを登録）、`authorization_probe.rb`（テスト専用のコントローラとルート。`reload_routes!` で片付ける）を使う
- テストの落とし穴: ヘルパーにキーワード引数（`with:` / `map:` など）があると、`resolve("groups" => [...])` のような波括弧なしの文字列キー Hash がキーワード引数として解釈される。第 1 引数は `{ ... }` で囲むか、追加の引数を位置引数にする
- 結合テストでのサインアウト: `allow_forgery_protection` が有効な間、トークンなしの `DELETE /logout` は拒否される。セッションを終わらせるだけなら Devise の `sign_out :user` を使う
- 最終検証（`/kiro-validate-impl`）: authentication の最新（`session_token` 追加を含む）へ `feat/entra-authorization` を rebase して統合した。競合は `db/schema.rb` と、`users` の列を完全一致で検証する 2 つのテスト（`roles` と `session_token` の両方を期待値に入れた）。`db:drop db:create db:migrate` で作り直したスキーマが手で解決した `schema.rb` と一致することを確認した
- 実 Entra ID テナントでの動作確認は行っていない（実通信は禁止。テストは WebMock + `OidcProviderStub` のみ）。手順書 9 章のチェックリストで、人がテナントで確認する
