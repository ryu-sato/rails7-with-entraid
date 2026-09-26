# Requirements Document

## Project Description (Input)
組織の Entra ID アカウントでアプリにサインインしたい利用者と、それを実装する開発チームがいる。現状は `rails new` 直後の雛形で認証がなく、誰でもアクセスできる。アプリ独自のパスワードやアカウントのライフサイクルを持たず、ID 管理を Entra ID に委譲した認証基盤に変える。

### 目指す状態
- 未ログインのユーザーが Entra ID でサインインでき、ログイン状態が Devise のセッションで管理される
- Entra ID のユーザーが `oid` + `tid` で一意に特定され、`User` レコードと対応付けられる
- 無操作タイムアウトとログインからの絶対時間上限でセッションが失効する
- ログアウト時に Entra ID 側のセッションも終了する（RP-Initiated Logout）

### アプローチ（discovery で決定済み）
- Devise（`omniauthable`, `timeoutable`）に omniauth_openid_connect を strategy として登録する
- Authorization Code Flow + PKCE（`discovery: true`, `response_type: :code`, `pkce: true`）。Access token は破棄する
- シングルテナントのエンドポイントを使い、`issuer` はテナント固有の v2.0 issuer（完全一致で検証）とする
- omniauth-rails_csrf_protection を導入し、ログイン開始は POST（`button_to`）で行う
- セッション寿命は Timeoutable と独自の絶対時間上限で制御し、Rememberable は使わない
- RP-Initiated Logout は gem 標準が `id_token_hint` を使わないため、Devise の sign-out 経路で自前実装する

### スコープ外
- roles / groups クレームの解釈、ロール保存、権限判定（`entra-authorization`）
- Front-channel Logout / Back-channel Logout
- Access token を使った API 呼び出し

詳細は `brief.md` を参照。

## Requirements
<!-- Will be generated in /kiro-spec-requirements phase -->
