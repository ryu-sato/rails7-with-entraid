# Technology Stack

## Architecture

Rails 8.1 のモノリス（Omakase 構成）。サーバーサイドレンダリングの HTML を基本とし、
Hotwire で動的な振る舞いを足す。JS のビルドステップは持たない（importmap）。
キャッシュ・ジョブ・WebSocket はすべて DB バックエンドの Solid 系で賄い、追加ミドルウェアを前提にしない。

## Core Technologies

- **Language**: Ruby 4.0（`.ruby-version`）
- **Framework**: Ruby on Rails 8.1（`config.load_defaults 8.1`）
- **Web Server**: Puma + Thruster（本番の HTTP キャッシュ / 圧縮）
- **Database**: SQLite 3（`config/database.yml`。本番は primary / cache / queue / cable の 4 DB 構成）

## Key Libraries

- **Hotwire**: turbo-rails / stimulus-rails。新しい JS は Stimulus コントローラとして書く
- **importmap-rails + propshaft**: Node / バンドラ不要のアセット配信。npm パッケージは `bin/importmap pin` で追加
- **Solid Cache / Solid Queue / Solid Cable**: `Rails.cache` / Active Job / Action Cable の標準実装
- **jbuilder**: JSON レスポンスが必要な場合のビュー
- **認証（未導入）**: Entra ID 連携は OIDC で行う想定。gem 選定は spec の設計フェーズで決める

## Development Standards

### Code Quality
- `rubocop-rails-omakase` のスタイルに従う（`.rubocop.yml` で継承、独自ルールは現状なし）

### Security
- Brakeman（静的解析）、bundler-audit（gem 脆弱性）、`importmap audit`（JS 依存）を CI で実行
- 秘密情報は Rails credentials（`config/credentials.yml.enc`）で管理し、平文でコミットしない

### Testing
- Minitest（Rails 標準）。`test/` 配下に models / controllers / integration / system を配置
- System テストは Capybara + Selenium（CI ではオプション扱い）

## Development Environment

### Required Tools
- Dev Container（`.devcontainer/`）: Ruby 4.0 イメージ + PostgreSQL サービス
- Node.js は不要（importmap 構成のため）

### Common Commands
```bash
# Setup:  bin/setup
# Dev:    bin/dev
# Test:   bin/rails test
# Lint:   bin/rubocop
# CI一式: bin/ci   (setup → rubocop → 各種 audit → brakeman → test → seeds)
```

## Key Technical Decisions

- **Omakase を崩さない**: Rails 8 のデフォルト（importmap, Solid 系, Kamal）を採用し、代替スタックは明確な理由がある場合のみ導入する
- **デプロイは Kamal**: Docker イメージを Kamal でデプロイし、`storage/` を永続ボリュームにマウント（SQLite 前提の構成）
- **DB は未確定**: アプリは SQLite で生成されているが、Dev Container は PostgreSQL と `DATABASE_URL` を提供している。どちらに寄せるかは要決定（Gemfile に `pg` は未追加）

---
_Document standards and patterns, not every dependency_
