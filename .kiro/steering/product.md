# Product Overview

Microsoft Entra ID（旧 Azure AD）によるサインインと、ロールに基づく権限判定を備えた Rails Web アプリケーション。
認証（OIDC）と認可（ロール → 権限）は実装済みで、業務ドメインの機能はまだない。

> 目的はリポジトリ名 `rails7-with-entraid` から推定したもの。プロダクトの対象ユーザーや業務ドメインが固まったらこのファイルを更新すること。
> Rails 7.2 で初期化している（当初 Rails 8 で誤って生成したため作り直した。`tech.md` 参照）。

## Core Capabilities

- **Entra ID によるシングルサインオン**: 組織アカウントでログインし、アプリ独自のパスワード管理を持たない。セッションは無操作と絶対時間の両方で失効し、ログアウト時は Entra ID 側も終了する
- **ロールに基づく認可**: Entra ID の割り当て（App Role またはグループ）をログインのたびにアプリ内ロールへ取り込む。ロールを持たない利用者はログインできず、権限は画面と操作の単位で判定する。方式はテナントの契約（Free / P1 / P2）に合わせて設定で選ぶ
- **標準的な Rails サーバーサイドレンダリング + Hotwire**: SPA フレームワークを使わず、Turbo / Stimulus でインタラクションを付与
- **Rails 7.2 標準構成**: Redis 等の外部ミドルウェアなしで動作

## Target Use Cases

- 社内・組織向けアプリで、既存の Entra ID テナントのアカウントでアクセス制御したいケース
- Rails 7 と Entra ID（OIDC）連携の構成を検証・雛形化するケース

## Value Proposition

- ID 管理を Entra ID に委譲し、アプリ側でパスワード・アカウントのライフサイクルを持たない
- Rails 標準構成を崩さず、最小限の追加で認証を組み込む

---
_Focus on patterns and purpose, not exhaustive feature lists_
_Updated: 2026-09-27 — 認証・認可の実装完了に合わせて現状の記述を更新_
