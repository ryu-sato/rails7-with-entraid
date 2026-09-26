# Product Overview

Microsoft Entra ID（旧 Azure AD）によるサインインを備えた Rails Web アプリケーション。
現時点では `rails new` 直後の雛形で、ドメイン機能・認証はまだ実装されていない。

> 目的はリポジトリ名 `rails7-with-entraid` から推定したもの。プロダクトの対象ユーザーや業務ドメインが固まったらこのファイルを更新すること。
> なお名前は "rails7" だが、実際の Rails バージョンは 8.1（`tech.md` 参照）。

## Core Capabilities

- **Entra ID によるシングルサインオン**: 組織アカウントでログインし、アプリ独自のパスワード管理を持たない（予定）
- **標準的な Rails サーバーサイドレンダリング + Hotwire**: SPA フレームワークを使わず、Turbo / Stimulus でインタラクションを付与
- **Rails 8 標準のインフラ一式**: Solid Cache / Solid Queue / Solid Cable により Redis 等の外部ミドルウェアなしで動作

## Target Use Cases

- 社内・組織向けアプリで、既存の Entra ID テナントのアカウントでアクセス制御したいケース
- Rails 8 と Entra ID（OIDC）連携の構成を検証・雛形化するケース

## Value Proposition

- ID 管理を Entra ID に委譲し、アプリ側でパスワード・アカウントのライフサイクルを持たない
- Rails の Omakase 構成を崩さず、最小限の追加で認証を組み込む

---
_Focus on patterns and purpose, not exhaustive feature lists_
