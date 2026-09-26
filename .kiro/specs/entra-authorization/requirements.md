# Requirements Document

## Project Description (Input)
Entra ID で管理しているグループやロールの割り当てに基づいて、アプリの機能へのアクセスを制御したい利用者と、それを実装する開発チームがいる。`entra-authentication` の実装後は Entra ID でログインした `User`（`oid` + `tid`）がいる状態になるが、ロール情報を保持しておらず権限判定もない。認証だけでは「ログインできる人」しか分からず、権限ごとの出し分けや拒否ができない。

### 目指す状態
- ログインのたびに ID token のクレームからロール配列が更新され、`User` に保存される
- ロールを 1 つも持たないユーザーはログインを拒否される
- groups 方式で overage が起きたユーザーは、理由を表示してログインを拒否される
- cancancan の `Ability` でロールごとの権限を定義でき、コントローラとビューで判定できる

### アプローチ（discovery で決定済み）
- ロール取得を「クレームからコード上のロール名の配列を得る」共通インターフェースとして切り出し、roles クレーム方式と groups クレーム方式を設定で切り替える
- `User` にロール（string）の配列を保存し、ログインのたびに更新する。ロール名は DB ではなくコードで管理する
- コードに存在しないロール、およびマッピングにないグループは無視し、結果が空ならログインを拒否する
- roles 方式（P1・P2）: App Role の「値」をコード上のロール名と一致させ、roles クレームの値を（既知のロールだけ残して）保存する
- groups 方式（Free）: グループ Object ID とロールのマッピングを config gem で管理する。overage（`groups` 欠落 + `_claim_names` / `_claim_sources`）を検知してログイン失敗とし、理由を表示する
- クレームは `auth.extra.raw_info` から取得する
- 権限は cancancan の `Ability` にロール → 権限を定義し、`authorize!` / `can?` で判定する

### スコープ外
- ログイン・セッション・ログアウトの基盤（`entra-authentication`）
- Graph API による overage 解決
- ロールの DB 管理と管理画面
- 業務リソースごとの詳細な権限設計
- Front-channel Logout

詳細は `brief.md` を参照。

## Requirements
<!-- Will be generated in /kiro-spec-requirements phase -->
