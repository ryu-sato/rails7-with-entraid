# Project Structure

## Organization Philosophy

Rails 標準の MVC レイヤー構成（Convention over Configuration）。
独自のディレクトリ層（`app/services` など）は、Rails 標準の置き場所で表現しきれなくなってから必要に応じて追加する。

## Directory Patterns

### Controllers
**Location**: `app/controllers/`
**Purpose**: HTTP の入出力。`ApplicationController` を継承し、認証などの横断処理はここ（または concern）に置く
**Example**: 認証必須化は `ApplicationController` の `before_action` で行い、公開ページ側で明示的にスキップする

### Models
**Location**: `app/models/`
**Purpose**: ドメインロジックと永続化。`ApplicationRecord` を継承
**Example**: 外部 ID（Entra ID の `oid` / `tid` 等）との紐付けはユーザーモデルの属性として持つ

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

### Tests
**Location**: `test/`
**Purpose**: `app/` の構造をミラーリング（`test/models/`, `test/controllers/`, `test/integration/`）

## Naming Conventions

- **Files**: snake_case（Ruby / JS とも）
- **Classes / Modules**: PascalCase。ファイル名と一致させ Zeitwerk の自動読み込みに乗せる
- **Controllers**: 複数形リソース名 + `Controller`（例: `SessionsController`）
- **Methods / variables**: snake_case、述語メソッドは `?` で終える

## Import Organization

Ruby は Zeitwerk による自動読み込みのため `require` は原則不要。
`lib/` も `config.autoload_lib` で自動読み込み対象（`lib/assets`, `lib/tasks` を除く）。

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
