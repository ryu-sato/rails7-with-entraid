# Brief: entra-authorization

## Problem
Entra ID で管理しているグループやロールの割り当てに基づいて、アプリの機能へのアクセスを制御したい。認証だけでは「ログインできる人」しか分からず、権限ごとの出し分けや拒否ができない。

## Current State
`entra-authentication` 実装後は、Entra ID でログインした `User`（`oid` + `tid`）がいる状態になる。ただしロール情報は保持しておらず、権限判定もない。

## Desired Outcome
- ログインのたびに ID token のクレームからロール配列が更新され、`User` に保存される
- ロールを 1 つも持たないユーザーはログインを拒否される
- groups 方式で overage が起きたユーザーは、理由を表示してログインを拒否される
- cancancan の Ability でロールごとの権限を定義でき、コントローラとビューで判定できる

## Approach
ロール取得を「クレームからコード上のロール名の配列を得る」共通インターフェースとして切り出し、2 方式を設定で切り替える。

- **共通ルール**:
  - `User` にロール（string）の配列を保存し、ID token 取得時（ログインのたび）に更新する
  - ロール名は DB ではなくコードで管理する
  - コードに存在しないロール、およびマッピングにないグループは無視する
  - 結果が空ならログインを拒否する
- **roles クレーム方式（P1・P2）**:
  - App Role の「値」をコード上のロール名と一致させ、roles クレームの値を（既知のロールだけ残して）そのまま保存する
  - アプリに割り当てた App Role のみがクレームに入るため overage は起きない
  - Entra 側の前提: App Roles の定義、エンタープライズアプリでのグループの割り当て、「割り当てが必要」を「はい」にする
  - 注意: App Roles ではグループの階層構造が反映されない
- **groups クレーム方式（Free）**:
  - グループ Object ID とロールのマッピングを config gem で管理し、groups クレームからロールを導出する
  - 出力対象はセキュリティグループに限定する（「割り当てたグループのみ」は P1・P2 のみ対応のため使えない）
  - overage（JWT は 200 グループ超）では `groups` クレームが欠落し、`_claim_names` / `_claim_sources` が入る。これを検知してログイン失敗とし、理由を表示する。Graph 呼び出しでの解決は対象外
  - 運用: 200 グループ超に所属するユーザーがいないか事前に確認する
- **クレームの取得元**: `auth.extra.raw_info` に ID token のクレームが含まれる（`roles`, `groups`）。userinfo エンドポイントは groups を返さない
- **権限**: cancancan の `Ability` にロール → 権限を定義する。ロール数が少ない前提のためシンプルに保つ

## Scope
- **In**:
  - `User` へのロール配列カラム追加（migration）
  - ロール定義（コード管理）
  - roles クレーム方式 / groups クレーム方式の 2 つのロール解決と、設定による切り替え
  - config gem による groups のマッピング設定
  - ログイン時のロール更新
  - ロール空・overage 時のログイン拒否と、その理由表示
  - cancancan の導入と `Ability` 定義、コントローラ / ビューでの判定（`authorize!` / `can?`）、権限なしの扱い
  - Entra ID 側の設定手順（App Roles、groups クレーム、事前確認方法）のドキュメント化
- **Out**:
  - ログイン・セッション・ログアウトの基盤（entra-authentication）
  - Graph API による overage 解決
  - ロールの DB 管理と管理画面
  - 実際の業務リソースごとの詳細な権限設計（ドメイン機能側で決める）
  - Front-channel Logout

## Boundary Candidates
- クレームからロールへの変換（roles 方式 / groups 方式の 2 つの解決戦略と共通ルール）
- ログイン時のロール同期と拒否の判定（callback の拡張点に接続）
- ロール定義と cancancan の Ability（権限判定）

## Out of Boundary
- OmniAuth / Devise の設定、`User` の同定、セッション寿命、ログアウト（entra-authentication が持つ）
- 業務ドメインごとの認可ルール本体
- Entra ID テナントの設定作業そのもの（本 spec は手順を文書化するのみ）

## Upstream / Downstream
- **Upstream**: entra-authentication（`User` モデル、OIDC callback の拡張点、`current_user`）。Entra ID の App Roles / groups クレーム設定
- **Downstream**: ドメイン機能（`can?` / `authorize!` を使って画面と操作を制御する）

## Existing Spec Touchpoints
- **Extends**: なし
- **Adjacent**: entra-authentication。callback の拡張点（ロール解決の呼び出し）と `User` モデルを共有する。拒否時のメッセージ表示は、失敗ハンドリングの仕組みを authentication のものに乗せる

## Constraints
- ロール名は DB を使わずコードで管理する
- groups は既定で GUID（Object ID）で届くため、マッピングのキーは GUID にする
- App Roles は Free / P1 / P2 いずれでも定義できるが、エンタープライズアプリへのグループ単位の割り当ては P1・P2 が必要。方式の選択はテナントの契約に依存する
- ロール変更はログイン時にしか反映されない。反映の遅延は entra-authentication のセッション絶対上限で制限する
- cancancan 3.6.x、config 5.6.x（Ruby 4.0 / Rails 7.2 で解決・require できることを viability チェックで確認済み）
