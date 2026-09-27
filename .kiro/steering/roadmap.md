# Roadmap

## Overview
Entra ID 管理のグループによる Web アプリの認可制御を実現する。認証は OIDC（Authorization Code Flow + PKCE）で Entra ID に直接接続し、Rails 側は Devise（omniauthable）+ omniauth_openid_connect で RP を実装する。ID token のクレーム（roles または groups）からロール配列を生成してユーザーに保存し、cancancan で権限を判定する。

現状はどの機能も未実装の `rails new` 直後の雛形（Rails 7.2 / Ruby 4.0 / SQLite）。認証基盤を先に作り、その上にロール取得と認可を載せる 2 spec 構成とする。

## Approach Decision
- **Chosen**: OIDC（Authorization Code Flow + PKCE）/ omniauth_openid_connect / Devise（omniauthable, timeoutable）/ cancancan / Entra ID 直結。ロール取得は roles クレーム方式（P1・P2）と groups クレーム方式（Free）の両対応
- **Why**:
  - OIDC は MS 推奨で、JWT 署名検証は SAML の XML 署名検証より攻撃面が狭い
  - omniauth_openid_connect は OmniAuth 公式チーム管理で、omniauth-entra-id は ID token を検証しない
  - Devise はコミュニティが大きく、Rodauth の利点が活きる要件ではない
  - ロール数が少ないため cancancan が素直
  - Entra ID 以外の IdP を使う可能性が低く、Keycloak 運用負荷が見合わない
- **Rejected alternatives**:
  - SAML 2.0（攻撃面が広い）
  - omniauth-entra-id（ID token 未検証、issue 対応が弱い）
  - Rodauth（少数開発、メリットが活きない）
  - Rails 8 認証ジェネレータ（Rails 7 のため対象外）
  - Pundit（ロール数が少なく過剰）
  - Keycloak 経由（運用負荷）

## Scope
- **In**:
  - OIDC ログイン
  - `oid` + `tid` によるユーザー特定
  - セッション寿命管理（無操作タイムアウト + 絶対時間上限）
  - RP-Initiated Logout
  - roles / groups クレームからのロール配列生成と保存
  - ロール未保持ユーザーのログイン拒否
  - groups の overage 時のログイン拒否
  - cancancan による権限定義
- **Out**:
  - Front-channel Logout（採用しない。必要になったら別 spec）
  - Back-channel Logout（Entra ID 未対応）
  - Microsoft Graph API 呼び出しによる overage 解決
  - Rememberable
  - アクセストークンの利用（破棄）
  - ドメイン機能、業務画面
  - DB 選定（SQLite / PostgreSQL）の最終決定

## Constraints
- Rails 7.2 / Ruby 4.0。Rails 8 固有機能は前提にしない
- シングルテナントのエンドポイントを使う。`issuer` は `https://login.microsoftonline.com/<TENANT_ID>/v2.0` の完全一致で検証されるため、`/common` や `/organizations` は使えない
- `discovery: true`, `response_type: :code`, `pkce: true`, omniauth-rails_csrf_protection 必須（ログイン開始は POST の `button_to`）
- ロール名は DB を使わずコード管理する。コードに存在しないロール、およびマッピングにないグループは無視する
- 秘密情報は Rails credentials または環境変数で管理する
- **viability チェックで判明した注意点**（詳細は各 brief）:
  - omniauth_openid_connect 0.8.0 は 2024-07 以降リリースがなく、`ostruct ~> 0.6.3` に依存する。バージョンを固定し、上流を監視する
  - RP-Initiated Logout は gem の標準機能だけでは不十分（`id_token_hint` が未使用）。Devise 側で自前実装する
  - roles / groups クレームは `auth.extra.raw_info` から取得できる

## Boundary Strategy
- **Why this split**: 「誰であるか（認証・セッション）」と「何ができるか（ロール取得・権限）」は変更理由が異なる。認証だけで単体で動作・検証でき、認可はその上に載る
- **Shared seams to watch**:
  - ログイン callback とロール同期。callback の拡張点（ロール解決の呼び出し）は authentication が用意し、実装は authorization が持つ
  - 「ロール配列が空ならログイン拒否」と「overage ならログイン拒否」はどちらも callback で起きる。拒否時の画面とメッセージの責務を分担する
  - `User` モデル。authentication が `oid` / `tid` を持たせ、authorization が `roles` 列を追加する（マイグレーションを分ける）
  - ID token の保存。RP-Initiated Logout の `id_token_hint` に使うため、authentication が保持する

## Specs (dependency order)
- [x] entra-authentication -- Devise + omniauth_openid_connect による Entra ID OIDC ログイン、oid/tid によるユーザー特定、セッション寿命管理、RP-Initiated Logout。Dependencies: none
- [x] entra-authorization -- roles / groups クレームからのロール配列生成・保存、ロール未保持・overage 時のログイン拒否、cancancan による権限定義。Dependencies: entra-authentication
