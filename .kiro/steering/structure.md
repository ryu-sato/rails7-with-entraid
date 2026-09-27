# Project Structure

## Organization Philosophy

Rails 標準の MVC レイヤー構成（Convention over Configuration）。
独自のディレクトリ層（`app/services` など）は、Rails 標準の置き場所で表現しきれなくなってから必要に応じて追加する。

## Directory Patterns

### Controllers
**Location**: `app/controllers/`
**Purpose**: HTTP の入出力。`ApplicationController` を継承し、認証などの横断処理はここ（または concern）に置く
**Example**: 認証必須化は `ApplicationController` の `before_action` で行い、公開ページ側で明示的にスキップする。権限なしの共通応答は concern（`AuthorizationHandling`）に集約して `ApplicationController` に include し、各コントローラは操作の前に `authorize!` を呼ぶだけにする

### Models
**Location**: `app/models/`
**Purpose**: ドメインロジックと永続化。`ApplicationRecord` を継承
**Example**: 外部 ID（Entra ID の `oid` / `tid` 等）との紐付けはユーザーモデルの属性として持つ
**PORO**: 1 つの機能を複数の小さなクラスで構成するときは `app/models/<名前空間>/` にまとめる（例: `Authorization::RoleSync`）。権限の定義は `Ability`、コードで持つ定数の定義は `Role` のように、名前空間の外に置く単一の定義元を作る

### Concerns
**Location**: `app/controllers/concerns/`, `app/models/concerns/`
**Purpose**: 複数クラスで共有する振る舞い（例: 認証ヘルパー）

### Front-end
**Location**: `app/javascript/controllers/`
**Purpose**: Stimulus コントローラ。`*_controller.js` の命名で自動登録される（`controllers/index.js`）
**Example**: `hello_controller.js` → `data-controller="hello"`

### Configuration
**Location**: `config/initializers/`, `config/credentials.yml.enc`
**Purpose**: 外部サービス（Entra ID の client id / tenant 等）の設定は initializer で読み込み、値は credentials または環境変数から取得する
**Settings**: 秘密でない設定は config gem（`config/settings.yml` + `config/settings/<環境>.yml`。`*.local.yml` は git 管理外で上書き用）。環境ごとに必ず選ぶ設定には共通の既定値を置かず、未指定なら起動時に失敗させる
**注意**: `config/initializers/` の読み込み時点では `app/` 配下の定数を参照できない（`NameError`）。参照する処理は `Rails.application.config.after_initialize` に置く。ゲートのように後から呼ばれるコードは、呼び出し時に定数を引く（リロードでも壊れない）

### Tests
**Location**: `test/`
**Purpose**: `app/` の構造をミラーリング（`test/models/`, `test/controllers/`, `test/integration/`）
**Support**: 共通のヘルパー・スタブ・テスト専用のコントローラは `test/support/`（テストヘルパーが自動で読み込む）。手順書と実装の設定名の一致は `test/docs/` で検証する
**Pitfall**: ヘルパーにキーワード引数があると、波括弧なしの `"key" => value` の Hash がキーワード引数として解釈される。第 1 引数は `{ ... }` で囲むか、追加の引数を位置引数にする

### Docs
**Location**: `docs/`
**Purpose**: 運用者向けの手順書（Entra ID 側の設定、方式の選び方、事前確認）。設定名は実装と一致させ、テストで検証する（`entra_id_setup.md`: 認証、`entra-authorization.md`: 認可）

## Naming Conventions

- **Files**: snake_case（Ruby / JS とも）
- **Classes / Modules**: PascalCase。ファイル名と一致させ Zeitwerk の自動読み込みに乗せる
- **Controllers**: 複数形リソース名 + `Controller`（例: `SessionsController`）
- **Methods / variables**: snake_case、述語メソッドは `?` で終える

## Import Organization

Ruby は Zeitwerk による自動読み込みのため `require` は原則不要。
`lib/` も `config.autoload_lib` で自動読み込み対象（`lib/assets`, `lib/tasks` を除く）。
**例外**: `lib/entra_auth/`（認証ライブラリ）は Zeitwerk の管理外で、`config/initializers/entra_auth.rb`（と `config/initializers/devise.rb`）から明示的に `require` する。Devise の initializer が起動中に `EntraAuth::Strategy` を参照するため、自動読み込みの準備を待てない。この規約の詳細は `docs/entra_id_setup.md` を参照。

JS は importmap の論理名で import する:
```javascript
import { Controller } from "@hotwired/stimulus"  // config/importmap.rb で pin した名前
import "controllers"                            // app/javascript/controllers
```

## Code Organization Principles

- ルーティングは `config/routes.rb` に RESTful リソースとして定義する
- コントローラは薄く保ち、ロジックはモデル（必要なら PORO / concern）へ
- 秘密情報をコードや initializer に直書きしない

---
_Document patterns, not file trees. New files following patterns shouldn't require updates_
_Updated: 2026-09-27 — 認可の実装で確立した配置の規約（PORO の名前空間、設定、initializer の制約、テスト支援）を追加_
