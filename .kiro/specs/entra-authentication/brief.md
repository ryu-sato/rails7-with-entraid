# Brief: entra-authentication

## Problem
組織の Entra ID アカウントでアプリにサインインしたい利用者と、それを実装する開発チームがいる。アプリ独自のパスワードやアカウントのライフサイクルを持たず、ID 管理を Entra ID に委譲したい。現状は認証がなく、誰でもアクセスできる。

## Current State
`rails new` 直後の雛形。Devise、OmniAuth、User モデルはなく、ルーティングもデフォルトのみ。

## Desired Outcome
- 未ログインのユーザーが Entra ID でサインインでき、ログイン状態が Devise のセッションで管理される
- Entra ID のユーザーが `oid` + `tid` で一意に特定され、`User` レコードと対応付けられる
- 無操作タイムアウトとログインからの絶対時間上限でセッションが失効する
- ログアウト時に Entra ID 側のセッションも終了する（RP-Initiated Logout）

## Approach
Devise（`omniauthable`, `timeoutable`）に omniauth_openid_connect を strategy として登録する。Authorization Code Flow で ID token / Access token を取得し、Access token は破棄する。

- **設定**: `discovery: true`, `response_type: :code`, `pkce: true`。シングルテナントで、`issuer` にはテナント固有の v2.0 issuer（`https://login.microsoftonline.com/<TENANT_ID>/v2.0`）を指定する
- **CSRF**: omniauth-rails_csrf_protection を導入し、ログイン開始は POST の `button_to` で行う
- **ユーザー特定**: `oid` + `tid` の組で一意にする。email などの可変属性では特定しない
- **セッション寿命**: Timeoutable と、ログイン時刻を元にした絶対時間上限の独自実装。ロール変更の反映がログイン時のみのため、絶対上限が必要。Rememberable は使わない
- **ログアウト**: gem の logout 機能は `id_token_hint` を使わない。Devise の sign-out 経路で `end_session_endpoint?post_logout_redirect_uri=...&id_token_hint=...` を自前で組み立てる。ID token はログイン時に保持する
- **未ログイン時の扱い**: 認証必須化は `ApplicationController` の `before_action` で行い、公開ページ側で明示的にスキップする（`structure.md` の方針）

### 依存 gem の注意点（viability チェック結果）
- omniauth_openid_connect 0.8.0 は最終リリースが 2024-07 で、`ostruct ~> 0.6.3` などに依存する。Ruby 4.0 では ostruct が bundled gem のため将来の競合リスクがあり、バージョンを固定して上流を監視する
- Devise 5.0.4 は Rails 7.2 で利用可能
- `post_logout_redirect_uri` は Entra のアプリ登録に登録が必要
- `id_token_hint` を省略すると Entra 側でアカウント選択画面が出るため、`id_token_hint` は付ける

## Scope
- **In**:
  - Devise / OmniAuth / omniauth-rails_csrf_protection の導入と初期設定
  - Entra ID 用 strategy 設定（credentials / 環境変数から `tenant_id`, `client_id`, `client_secret` を読む）
  - `User` モデルと migration（`oid`, `tid` に一意制約。初回ログインで作成）
  - OIDC callback の処理と失敗時のハンドリング
  - Timeoutable と絶対時間上限のセッション失効
  - RP-Initiated Logout
  - 認証必須化と、ログイン画面 / ログアウト UI
  - Entra ID 側の設定手順（リダイレクト URI、post-logout URI など）のドキュメント化
- **Out**:
  - roles / groups クレームの解釈とロール保存、権限判定（entra-authorization）
  - Front-channel Logout（対象外）
  - Back-channel Logout（Entra ID 未対応）
  - Rememberable
  - Access token を使った API 呼び出し
  - パスワード認証などの Entra ID 以外の認証手段

## Boundary Candidates
- OmniAuth / Devise の strategy 設定と callback ルーティング
- `User` の同定と作成（`oid` + `tid`）
- セッション寿命ポリシー（無操作 + 絶対時間）
- RP-Initiated Logout（Entra ID 側セッションの終了）

## Out of Boundary
- ロール、権限、cancancan の Ability（entra-authorization が持つ）
- 「ロールが空ならログイン拒否」の判定ロジック。callback にロール解決を差し込む拡張点だけを用意する
- ドメイン機能と業務画面
- DB 選定（SQLite / PostgreSQL）の最終決定。本 spec は現状の DB 設定で動くことを前提とする

## Upstream / Downstream
- **Upstream**: Rails 7.2 の雛形、Entra ID テナントとアプリ登録（リダイレクト URI、クライアントシークレット）
- **Downstream**: entra-authorization（callback でロールを取得・保存し、拒否を判定する）。ドメイン機能（`current_user` を利用する）

## Existing Spec Touchpoints
- **Extends**: なし
- **Adjacent**: entra-authorization（`User` モデルと callback を共有する）。マイグレーションは分け、callback の拡張点を境界とする

## Constraints
- Rails 7.2 / Ruby 4.0。Rails 8 の認証ジェネレータは使わない
- シングルテナントのエンドポイントのみ。`issuer` は完全一致で検証されるため、`/common`・`/organizations`・`{tenantid}` プレースホルダは使えない
- アプリ登録は v2.0 token（`accessTokenAcceptedVersion` = 2）を前提とする。v1 では `sts.windows.net` issuer になり検証に失敗する
- Devise の `omniauth_path_prefix` と Entra のリダイレクト URI を一致させる
- 秘密情報は credentials または環境変数で管理し、コードに直書きしない
- ID token / Access token / リフレッシュトークンの有効期限は Entra 側の仕様（リフレッシュとセッションのトークン期限は設定不可）に依存するため、セッション寿命はアプリ側で制御する
