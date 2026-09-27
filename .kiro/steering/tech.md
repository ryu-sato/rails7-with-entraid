# Technology Stack

## Architecture

Rails 7.2 のモノリス。サーバーサイドレンダリングの HTML を基本とし、
Hotwire で動的な振る舞いを足す。JS のビルドステップは持たない（importmap）。
アセット配信は Sprockets。キャッシュ・ジョブ・WebSocket は Rails 7.2 標準の実装（メモリ / async / async アダプタ）を使う。

## Core Technologies

- **Language**: Ruby 4.0（`.ruby-version`）
- **Framework**: Ruby on Rails 7.2（`config.load_defaults 7.2`）
- **Web Server**: Puma
- **Database**: SQLite 3（`config/database.yml`。開発・テストは `storage/*.sqlite3`）

## Key Libraries

- **Hotwire**: turbo-rails / stimulus-rails。新しい JS は Stimulus コントローラとして書く
- **importmap-rails + sprockets-rails**: Node / バンドラ不要のアセット配信。npm パッケージは `bin/importmap pin` で追加
- **jbuilder**: JSON レスポンスが必要な場合のビュー
- **認証**: Entra ID と OIDC（Authorization Code Flow + PKCE）で直結する。Devise（omniauthable / timeoutable）+ omniauth_openid_connect + omniauth-rails_csrf_protection。Entra ID 固有の処理（検証済み ID token の取り出し、絶対時間上限、ログアウト URL、サインイン可否ゲート）は `lib/entra_auth/` に置く。パスワード認証や Rememberable は使わない
- **認可**: cancancan。ロールごとの権限は `Ability` に定義する。ロール名は DB ではなくコード（`Role`）で管理する
- **設定**: config gem（`Settings`）で非秘密の設定（ロール取得方式、グループ → ロールの対応表）を持つ。秘密（クライアントシークレット等）は環境変数 / credentials

## Development Standards

### Code Quality
- `rubocop-rails-omakase` のスタイルに従う（`.rubocop.yml` で継承、独自ルールは現状なし）

### Security
- Rails 7.2 系は 2026-08-09 にサポートが終了しており、Brakeman の EOLRails 警告は `config/brakeman.ignore` で「了承したリスク」として除外している（解消ではない。7.2.4 が最終リリースで、以降のセキュリティ修正はない）。解消には Rails 8.1 以降への更新が必要で、別 spec で判断する。Rails を更新したら除外エントリを削除する（`test/config/brakeman_ignore_test.rb` が更新を検知して失敗する）
- Brakeman（静的解析）を CI で実行。`bundler-audit` は Gemfile 未導入のため必要になったら追加する
- 秘密情報は Rails credentials（`config/credentials.yml.enc`）で管理し、平文でコミットしない

### Testing
- Minitest（Rails 標準）。`test/` 配下に models / controllers / integration / system を配置
- **外部通信をしない**: WebMock で `disable_net_connect!` を有効にし、IdP は `test/support/oidc_provider_stub.rb` のスタブ（テスト用の鍵）で代替する。実際の Entra ID にはテストからも開発時の操作からも接続しない（discovery が実ホストへ飛ぶため）
- 結合テストは OmniAuth のモックではなく、実際の Strategy をスタブに通す（`test/support/` の共通部品を使う）
- System テストは Capybara + Selenium（CI ではオプション扱い）

## Development Environment

### Required Tools
- Dev Container（`.devcontainer/`）: Ruby 4.0 イメージ + PostgreSQL サービス（`DATABASE_URL` が設定される。SQLite で動かす場合は `env -u DATABASE_URL bin/rails ...`）
- Node.js は不要（importmap 構成のため）

### Common Commands
```bash
# Setup:  bin/setup
# Dev:    bin/dev
# Test:   bin/rails test
# Lint:   bin/rubocop
```

## Key Technical Decisions

- **Rails 7.2 を採用**: 当初 Rails 8 で初期化したが、Rails 7 系で作り直した。Rails 8 固有機能（Solid 系、Propshaft、Kamal、認証ジェネレータ等）は前提にしない
- **Ruby 4.0 との組み合わせ**: Rails 7.2 の公式サポート Ruby は 3.3 までのため、非互換が出た場合は Ruby / gem 側で対処する
- **デプロイ方式は未確定**: 生成された `Dockerfile` はあるが、デプロイツールは未選定
- **DB は未確定**: アプリは SQLite で生成されているが、Dev Container は PostgreSQL と `DATABASE_URL` を提供している（Gemfile に `pg` は未追加）。どちらに寄せるかは要決定。決まるまでは DB 依存の型（配列など）を避け、JSON カラムで持つ（例: `users.roles`）。DB を決めたら、両方の DB で検証していない項目（JSON カラムの既定値など）を確認する
- **認証・認可の方式**: OIDC 直結（SAML、omniauth-entra-id は不採用）。ロールは ID token のクレームだけから導出し、Microsoft Graph は呼ばない。方式の選定理由と範囲は `roadmap.md` を参照
- **Rails 7.2 の EOL は了承済みのリスク**: `Security` の項を参照

---
_Document standards and patterns, not every dependency_
_Updated: 2026-09-27 — 認証・認可の gem と設計判断、テストの外部通信禁止の規約を追加_
