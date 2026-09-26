# Research & Design Decisions

## Summary
- **Feature**: `entra-authentication`
- **Discovery Scope**: New Feature（`rails new` 直後の雛形に認証基盤を新設。外部 IdP 連携を含むため full discovery）
- **Key Findings**:
  - devise 5.0.4 / omniauth 2.1.4 / omniauth_openid_connect 0.8.0 / openid_connect 2.5.0 / omniauth-rails_csrf_protection 2.0.1 は、Ruby 4.0 + Rails 7.2.4 で解決・require できる（全て MIT。viability チェックで確認済み）
  - omniauth_openid_connect 0.8.0 では、ID token 検証エラー（`InvalidToken` 系）と `JSON::JWT::Exception` は `StandardError` 派生（実装時に `ancestors` で確認。当初の調査の「`Exception` 派生」は誤り）で、OmniAuth の `call!` が `fail!(e.message, e)` に変換するため 500 にはならない。ただし失敗キーが例外メッセージそのもので不安定なうえ、トークンや IdP の本文が漏れうる。継承した strategy でキーを正規化する必要がある
  - Devise は `omniauthable` のみだと sessions のルートとコントローラを生成しない。ログイン画面とログアウトのルートは自前で定義する
  - Entra ID v2.0 の logout エンドポイントで文書化されているのは `post_logout_redirect_uri` と `logout_hint` のみ。`id_token_hint` は文書化されていない。また ID token（約 1.5〜3KB）は Cookie セッション（実効 約 2.5〜3KB）に入れると `CookieOverflow` の恐れがある。このため logout は `logout_hint` 方式にし、ID token を保持しない

## Research Log

### omniauth_openid_connect 0.8.0 の挙動（gem のソースを読んだ結果）
- **Context**: callback、失敗処理、logout、`id_token` の扱いが設計を左右するため
- **Sources Consulted**: 0.8.0 の `lib/omniauth/strategies/openid_connect.rb`、openid_connect 2.5.0 の `id_token.rb`
- **Findings**:
  - 既定の strategy 名は `openid_connect`。Devise 経由のパスは `/users/auth/openid_connect`、callback は `/users/auth/openid_connect/callback`
  - `discovery: true` のとき、`issuer` から discovery して authorization / token / jwks / end_session の各 endpoint を取得する。`identifier`・`secret`・`redirect_uri` だけ設定すればよい
  - PKCE: `pkce: true` で S256。verifier は session に保存され、token 交換で削除される
  - state（`require_state`）と nonce（`send_nonce`）は既定で有効。不一致は `fail!(:csrf_detected)` または `InvalidNonce`
  - 検証されるもの: 署名、`exp`、`iss`（`options.issuer` と完全一致）、`nonce`、`aud`。**検証されないもの: `tid`、`nbf`、`iat`**
  - `env['omniauth.auth']`: `uid`（既定 `sub`）、`info`、`credentials.id_token`（生の JWT）、`extra.raw_info`（userinfo 応答と ID token クレームをマージしたもの。`oid` / `tid` / `login_hint` を含む）
  - `user_info` は userinfo endpoint（Microsoft Graph）へ HTTP 要求を行う。Graph が使えないとサインインが失敗しうる
  - 失敗時: `error` パラメータは CallbackError、`fail!` のキーは `:csrf_detected` / `:missing_code` / `:invalid_jwt_algorithm` / `:timeout` / `:failed_to_connect` など。Devise は `omniauth_callbacks#failure` へ回す
  - **落とし穴（実装時に訂正）**: `OpenIDConnect::ResponseObject::IdToken::InvalidToken`（< `OpenIDConnect::Exception` < `StandardError`）も `JSON::JWT::Exception` も `StandardError` 派生で、OmniAuth の `call!` が rescue して `fail!(e.message, e)` にする。失敗キーが例外メッセージになる点が問題。以下は調査時の記述（不正確）: `ExpiredToken` / `InvalidIssuer` / `InvalidNonce` / `InvalidAudience` と `JSON::JWS::VerificationFailed` は strategy に rescue されず、ミドルウェアから生の例外として抜ける（本番では 500）
  - 組み込みの logout は `/users/auth/openid_connect/logout`（`other_phase`）。`id_token_hint` オプションは宣言だけで使われず、`post_logout_redirect_uri` のみが付く。Devise の sign-out 経路とは別物
- **Implications**:
  - strategy を継承し、request phase と callback phase を rescue して `fail!` に変換する（要件 4.2）
  - `tid` の検証は自前で行う（要件 2.5）。`iss` の完全一致で実質は固定されるが、防御を二重にする
  - logout は gem の機能を使わず、アプリ側で URL を組み立てる

### Entra ID v2.0（単一テナント）の設定
- **Sources Consulted**: Microsoft Learn `id-token-claims-reference`、`v2-protocols-oidc`
- **Findings**:
  - 単一テナントの discovery の `issuer` は `https://login.microsoftonline.com/{tenant GUID}/v2.0`。token の `iss` と一致する。`common` / `organizations` はプレースホルダ `{tenantid}` を含むため、完全一致検証が失敗する
  - v2.0 の ID token には `oid`（テナント内で不変のユーザー ID）と `tid` が既定で入る（`oid` は `profile` scope が必要）。`sub` はアプリごとに異なる
  - `email` は管理ユーザーで空のことがあり、変更もされうる。識別キーには使えない（要件 3.4）
  - `logout_hint` を使うには、アプリ登録で ID token に `login_hint` のオプションクレームを追加する必要がある。UPN や電話番号は `logout_hint` に使ってはならない
  - v1 token（`accessTokenAcceptedVersion` = 1）は `sts.windows.net` の issuer になり検証に失敗する
- **Implications**: 設定手順書（要件 8.5）に、v2.0 token、`login_hint` オプションクレーム、リダイレクト URI、サインアウト後 URI を必須項目として載せる

### Entra ID の RP-Initiated Logout
- **Findings**:
  - endpoint: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout`（discovery の `end_session_endpoint` と同じ）
  - 文書化されているパラメータ: `post_logout_redirect_uri`（アプリ登録済みの URI と一致が必要）、`logout_hint`（アカウント選択を省略する）
  - `id_token_hint` / `state` / `client_id`: **文書化されていない（UNVERIFIED）**。期限切れの ID token がヒントとして通るかも不明
  - `post_logout_redirect_uri` が callback 以外の URL でも受理されるかは UNVERIFIED。安全のため、サインアウト後の URL を Web のリダイレクト URI として登録する
- **Implications**:
  - `logout_hint` 方式を採る。`login_hint` クレームがない場合は、ヒントなし（アカウント選択が出る）に縮退する。それでも要件 7.1・7.2 は満たす
  - ID token を保持しないため、Cookie 肥大の問題も避けられる
  - endpoint はテナント ID から決定的に組み立てられるため、logout のために Entra ID へ HTTP 要求を行わない（要件 7.5）

### Devise 5.0.4
- **Findings**:
  - `devise :omniauthable, omniauth_providers: [:openid_connect]` で `omniauth_callbacks` のルートのみ生成される。`database_authenticatable` がないと sessions のルートとコントローラは存在しない
  - `authenticatable_salt` は `database_authenticatable` なしだと nil を返し、セッションのシリアライズは `[id, nil]` で成立する。email 列も `encrypted_password` 列も不要
  - `case_insensitive_keys` / `strip_whitespace_keys` は email 列がない場合に備えて空配列にする（未検証の懸念を避ける）
  - `sign_out_via` の既定は `:delete`。`sign_out_all_scopes` が true だとセッション全体がリセットされる
  - Timeoutable: `config.timeout_in`。Warden の `after_set_user` フックで `last_request_at` を見る。失効時のメッセージキーは `devise.failure.timeout`
  - 絶対時間の上限は Devise に組み込みがない。`Warden::Manager.after_set_user` で `login_at` を比較して失効させる方式が最も単純
  - FailureApp は `new_user_session_url` が未定義だと `root_url` へ回す。root が保護対象だと無限リダイレクトになるため、`new_user_session` という名前のルートを自前で定義する
  - 5.0.4 は Referer 経由のオープンリダイレクトの修正を含む（CVE-2026-40295）。5.0.4 以上に固定する
  - 認証開始のリンクは外部ドメインへ遷移するため、Turbo の fetch が CORS で失敗する。`data: { turbo: false }` が必要
- **Implications**: ルート・コントローラ・FailureApp との接続を設計に明記する

### omniauth-rails_csrf_protection 2.0.1 / Rails 7.2
- **Findings**: request phase は POST のみ許可（`allowed_request_methods` の既定）。`button_to` が認証トークンを付ける。GET を許可すると CSRF 保護が無意味になるため広げない
- **Implications**: サインイン開始は `button_to`（POST）。テストでは `OmniAuth.config.test_mode` を使う（検証フェーズは通る）

### Cookie セッションと ID token
- **Findings**: Rails の CookieStore は 4096 バイト上限（暗号化・base64 後）。ID token を入れると `CookieOverflow` の恐れがある
- **Implications**: ID token は保持しない。セッションには小さい値（`login_at`、`last_request_at`、`logout_hint`）だけを置く

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| Devise + OmniAuth strategy を継承（採用） | Devise の omniauthable に、失敗処理を強化した strategy を登録する | 既定のセッション管理・Timeoutable を再利用できる。継承は薄い | gem の内部（メソッド名）への依存が残る | 継承は `request_phase` / `callback_phase` の rescue に限定する |
| gem を素のまま使う | 継承せず標準の strategy を使う | 実装が最小 | ID token 検証エラーが 500 になり要件 4.2 を満たせない | 不採用 |
| ミドルウェアで例外を包む | Rack ミドルウェアで `Exception` を捕捉する | strategy に触れない | 範囲が広すぎ、他の例外も飲み込む | 不採用 |
| OIDC を自前実装 | `openid_connect` gem を直接使う | 完全に制御できる | 検証・PKCE・state を自前で持つことになり攻撃面が増える | 不採用 |

## Design Decisions

### Decision: ID token を保持せず `logout_hint` で logout する
- **Context**: 要件 7.3（サインアウト時にアカウント選択を求めない）と、Cookie セッションの容量制限
- **Alternatives Considered**:
  1. `id_token_hint` 方式（discovery 時の方針）— Entra の v2.0 logout で文書化されておらず、ID token の保存先も要る
  2. ID token を暗号化カラムに保存 — 1 ユーザー 1 トークンで、セッション単位でなく、機密の保持が増える
  3. `logout_hint` 方式 — 文書化された仕組みで、保持する値は小さい
- **Selected Approach**: 3。ログイン時に `raw_info["login_hint"]` をセッション（`warden.session`）に保存し、logout URL に付ける。クレームがなければヒントなしで縮退する
- **Rationale**: 文書化された仕様に乗り、Cookie に収まり、秘密情報の保持を増やさない
- **Trade-offs**: Entra 側で `login_hint` オプションクレームの追加が必要。追加漏れでも logout は成功するが、アカウント選択が出る
- **Follow-up**: 実機の Entra ID で `login_hint` の有無と logout の挙動を確認する。brief と roadmap にある `id_token_hint` の記述は、この決定で置き換わる

### Decision: strategy を継承して失敗を `fail!` に集約する
- **Context**: `InvalidToken` 系は `StandardError` 派生で OmniAuth が rescue するが、失敗キーが例外メッセージそのものになり不安定・漏えいのおそれがある（当初は `Exception` 派生と誤認していた）
- **Selected Approach**: `EntraAuth::Strategy < OmniAuth::Strategies::OpenIDConnect`。`request_phase` / `callback_phase` を、`StandardError` と、`OpenIDConnect::ResponseObject::IdToken::InvalidToken`、`JSON::JWT::Exception` で rescue する。`fail!(:invalid_id_token | :discovery_failed | ...)` へ変換する。`Exception` 全体は rescue しない
- **Rationale**: 捕捉範囲を既知の検証エラーに限定し、`SystemExit` などを飲み込まない
- **Follow-up**: （確認済み）`JSON::JWT::Exception` も `StandardError` 派生。テストで固定した

### Decision: userinfo endpoint に依存しない
- **Context**: `user_info` が Microsoft Graph への HTTP 要求を伴う
- **Selected Approach**: サインインに使うクレームは検証済みの ID token のみ（`oid` / `tid` / `name` / `email` / `login_hint`）。gem の内部を上書きして userinfo 呼び出しを避ける。実装が gem の内部に深く依存する場合は、標準の挙動を許容し、失敗はサインイン失敗として扱う
- **Rationale**: サインインの成否が Graph の可用性に左右されないようにする
- **Follow-up**: 実装時に上書きの可否を確認する。不可なら後者へ縮退する（Open Question に記載）

### Decision: ログイン画面とログアウトは Devise ではなく自前のルート
- **Selected Approach**: `devise_scope :user` の中で `get "login"`（名前 `new_user_session`）と `delete "logout"`（名前 `destroy_user_session`）を定義する。`SessionsController` は `ApplicationController` を継承する
- **Rationale**: `omniauthable` のみでは sessions が生成されない。`new_user_session` を定義すれば FailureApp が正しくログイン画面へ誘導する

### Decision: gem・設定値の読み込み
- **Selected Approach**: `lib/entra_auth/` は Zeitwerk の管理から外し、`config/initializers/entra_auth.rb` から明示的に `require` する
- **Rationale**: Devise の初期化子で `strategy_class` を参照するため、初期化中に再読み込み対象の定数を触らないようにする
- **Trade-offs**: 変更にはサーバー再起動が必要になる

### Decision: セッション寿命の既定値
- **Selected Approach**: 無操作 30 分（Devise の既定）、絶対 8 時間。環境変数で変更可能
- **Rationale**: ソースに値の指定がないため、一般的な業務アプリの目安を置く。ロール変更の反映遅延の上限は絶対時間で決まる。運用者が調整できる（要件 6.6）
- **Follow-up**: 運用要件が固まったら値を見直す

## Risks & Mitigations
- omniauth_openid_connect のリリースが 2024-07 で止まっており、`ostruct ~> 0.6.3` に依存する — Gemfile で `~> 0.8.0` に固定し、`bundle outdated` と上流の issue を監視する
- strategy の継承が gem の内部に依存する — 上書きを `request_phase` / `callback_phase` の rescue に限定し、例外注入のテストで固定する。gem 更新時は必ず再実行する
- Entra ID の logout の挙動（`logout_hint`、`post_logout_redirect_uri` の URI）が文書と異なる可能性 — 実機で確認するチェックリストを設定手順書に入れる。縮退動作（アカウント選択の表示）でも要件 7.1・7.2 は満たす
- 同時サインインによるユーザーの重複作成 — `(tid, oid)` の一意制約と `RecordNotUnique` の再取得で防ぐ
- 認証が失敗したユーザーでも `User` レコードが作られる（ゲートの拒否は作成後）— 識別子のみの記録であり、権限は与えない。文書化する
- 設定不備のまま本番へ出る — 本番の起動時に検証し、ログイン画面でも検証する

## References
- [Microsoft identity platform and OpenID Connect](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc) — logout endpoint とパラメータ
- [ID token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference) — `oid` / `tid` / `login_hint`
- [omniauth_openid_connect](https://github.com/omniauth/omniauth_openid_connect) — strategy の実装（`openid_connect.rb`）と issue #166（issuer の完全一致）、PR #149（logout）
- [Devise](https://github.com/heartcombo/devise) — omniauthable / timeoutable
- [omniauth-rails_csrf_protection](https://github.com/cookpad/omniauth-rails_csrf_protection) — POST 限定のサインイン開始
