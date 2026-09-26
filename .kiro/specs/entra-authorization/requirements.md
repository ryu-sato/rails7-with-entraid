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

## Introduction
本 spec は、Entra ID で管理されたロール・グループの割り当てをアプリの権限として取り込み、機能へのアクセスを制御する。ログインのたびに ID token のクレームからアプリ内ロールを導出して利用者に保存し、ロールを持たない利用者や解決できない利用者のログインを拒否し、保存されたロールに基づいて画面と操作の可否を判定できるようにする。ロール取得方式は、Entra ID テナントの契約（Free / P1 / P2）に応じて 2 方式から設定で選択できる。

## Boundary Context
- **In scope**:
  - ログイン時のロール導出・保存・更新（roles クレーム方式 / groups クレーム方式と、その切り替え）
  - ロール空・overage 時のログイン拒否と理由表示
  - アプリ内ロールの定義と、ロールごとの権限定義・判定（コントローラ / ビュー）、権限なし時の扱い
  - Entra ID 側設定手順（App Roles、groups クレーム、事前確認方法）の文書化
- **Out of scope**:
  - ログイン・セッション・ログアウトの基盤（`entra-authentication`）
  - Graph API による overage 解決
  - ロールの DB 管理と管理画面
  - 業務リソースごとの詳細な権限設計（ドメイン機能側で決める）
  - Front-channel Logout
  - Entra ID テナントの設定作業そのもの（手順の文書化のみ）
- **Adjacent expectations**:
  - `entra-authentication` が、Entra ID で認証された利用者の特定（`oid` + `tid`）、ログイン処理の中でロール解決を呼び出せる拡張点、現在の利用者の参照、およびログイン失敗時のメッセージ表示の仕組みを提供する。本 spec はそれらの上でロールを扱う
  - ロールの変更はログイン時にのみ反映される。反映の遅延の上限は `entra-authentication` のセッション絶対上限で制限される
  - ドメイン機能は、本 spec が提供する権限判定を使って画面と操作を制御する

## Requirements

### Requirement 1: ロール定義とロールの保存
**Objective:** As a 開発チーム, I want アプリ内で有効なロールをコードで定義し、利用者ごとに保持したい, so that Entra ID の割り当てをアプリの権限判定に使える

#### Acceptance Criteria
1. The Authorization Module shall アプリ内で有効なロール名の一覧をコード上で定義する
2. The Authorization Module shall 各利用者に対して、0 個以上のロール名の配列を保持する
3. The Authorization Module shall ロール名の定義にデータベース上のロール管理を必要としない
4. The Authorization Module shall 既存の利用者に対しても、ロールを持たない状態で導入できる

### Requirement 2: ログイン時のロール更新
**Objective:** As a 利用者, I want ログインのたびに Entra ID 上の最新の割り当てがアプリのロールに反映されてほしい, so that 割り当て変更後に再ログインすれば新しい権限で操作できる

#### Acceptance Criteria
1. When 利用者が Entra ID で認証に成功してログインする, the Authorization Module shall その利用者のロールを ID token のクレームから導出して保存済みのロールを置き換える
2. When 利用者が再度ログインし、Entra ID 上の割り当てが変更されている, the Authorization Module shall 変更後の割り当てに対応するロールのみを保存する
3. The Authorization Module shall ロールの導出結果から、コード上で定義されていないロールを除外する
4. The Authorization Module shall ロールの導出結果に、同一のロールを重複して含めない
5. While 利用者がログイン済みである, the Authorization Module shall 次回のログインまで保存済みのロールを変更しない

### Requirement 3: roles クレーム方式によるロール解決
**Objective:** As a 開発チーム, I want App Role の割り当てからロールを解決したい, so that P1・P2 テナントでグループ単位の割り当てをそのままアプリのロールに使える

#### Acceptance Criteria
1. Where roles クレーム方式が選択されている, when ID token に roles クレームが含まれる, the Authorization Module shall roles クレームの各値のうち、コード上で定義されたロール名と一致するものをロールとして採用する
2. Where roles クレーム方式が選択されている, if roles クレームが存在しない, then the Authorization Module shall 採用するロールを空とする
3. Where roles クレーム方式が選択されている, if roles クレームにコード上で定義されていない値のみが含まれる, then the Authorization Module shall 採用するロールを空とする
4. Where roles クレーム方式が選択されている, the Authorization Module shall groups クレームの内容をロール導出に使用しない

### Requirement 4: groups クレーム方式によるロール解決
**Objective:** As a 開発チーム, I want グループ Object ID とロールの対応表からロールを解決したい, so that Free テナントでも Entra ID のグループでアクセスを制御できる

#### Acceptance Criteria
1. Where groups クレーム方式が選択されている, the Authorization Module shall グループ Object ID とロール名の対応を設定として保持する
2. Where groups クレーム方式が選択されている, when ID token に groups クレームが含まれる, the Authorization Module shall 対応表に存在するグループ Object ID に対応するロールを採用する
3. Where groups クレーム方式が選択されている, the Authorization Module shall 対応表に存在しないグループを無視する
4. Where groups クレーム方式が選択されている, if 対応表がコード上で定義されていないロール名を参照している, then the Authorization Module shall そのロールを採用しない
5. Where groups クレーム方式が選択されている, if groups クレームが存在せず overage を示す情報も存在しない, then the Authorization Module shall 採用するロールを空とする
6. Where groups クレーム方式が選択されている, the Authorization Module shall roles クレームの内容をロール導出に使用しない

### Requirement 5: 方式の切り替え
**Objective:** As a 開発チーム, I want テナントの契約に合わせてロール取得方式を設定で切り替えたい, so that コード変更なしに Free / P1 / P2 のいずれのテナントにも対応できる

#### Acceptance Criteria
1. The Authorization Module shall roles クレーム方式と groups クレーム方式のうち、設定で指定された 1 つをロール解決に使用する
2. If 方式の設定が未指定である, then the Authorization Module shall 起動時にその旨を示すエラーを出して不完全な状態で動作しない
3. If 方式の設定が未対応の値である, then the Authorization Module shall 起動時にその旨を示すエラーを出して不完全な状態で動作しない
4. The Authorization Module shall 方式によらず同一の規則（コード上で定義されたロールのみ採用、重複なし、結果が空ならログイン拒否）を適用する

### Requirement 6: ロールを持たない利用者のログイン拒否
**Objective:** As a 開発チーム, I want どのロールも持たない利用者をログインさせたくない, so that 権限のない利用者が認証だけでアプリに入れないようにできる

#### Acceptance Criteria
1. When ロールの導出結果が空である, the Authorization Module shall ログインを拒否し、利用者をログイン済みの状態にしない
2. When ロールの導出結果が空でログインを拒否する, the Authorization Module shall ロールが割り当てられていないためにログインできなかったことを利用者に表示する
3. When ロールの導出結果が空でログインを拒否する, the Authorization Module shall 以前に保存されたロールを、拒否後の権限判定に使用しない
4. When 過去にロールを持っていた利用者の割り当てが Entra ID 上で全て取り消され、その利用者が再度ログインする, the Authorization Module shall ログインを拒否する

### Requirement 7: groups 方式における overage 時のログイン拒否
**Objective:** As a 利用者, I want グループ数が多すぎてロールを判定できない場合にその理由を知りたい, so that 管理者に適切に問い合わせられる

#### Acceptance Criteria
1. Where groups クレーム方式が選択されている, when ID token が overage（所属グループ数が上限を超え groups クレームが含まれない状態）を示している, the Authorization Module shall ログインを拒否し、利用者をログイン済みの状態にしない
2. When overage によりログインを拒否する, the Authorization Module shall 所属グループ数が多いためロールを判定できなかったことを利用者に表示する
3. When overage によりログインを拒否する, the Authorization Module shall 以前に保存されたロールを、拒否後の権限判定に使用しない
4. The Authorization Module shall overage の解決のために外部 API を呼び出さない
5. Where roles クレーム方式が選択されている, the Authorization Module shall overage を理由とするログイン拒否を行わない

### Requirement 8: ログイン拒否時の表示と扱い
**Objective:** As a 利用者, I want ログインできなかった理由が区別して分かってほしい, so that 自分で対処できるか管理者への連絡が必要かを判断できる

#### Acceptance Criteria
1. When ロールに起因してログインが拒否される, the Authorization Module shall 拒否の理由（ロール未割り当て / overage）を区別できる文言で利用者に表示する
2. The Authorization Module shall ロール起因のログイン拒否の表示に、クレームの生の内容やグループ Object ID を含めない
3. When ロールに起因してログインが拒否される, the Authorization Module shall 利用者が再度ログインを試行できる画面に遷移させる
4. When ロールに起因してログインが拒否される, the Authorization Module shall 拒否の理由を運用者が確認できる形で記録する

### Requirement 9: ロールごとの権限定義と判定
**Objective:** As a 開発チーム, I want ロールごとに許可する操作を定義し、画面と操作で判定したい, so that 権限に応じた出し分けと拒否ができる

#### Acceptance Criteria
1. The Authorization Module shall ロールごとに許可する操作を 1 か所で定義できる
2. When 利用者が複数のロールを持つ, the Authorization Module shall いずれかのロールが許可する操作を、その利用者に許可する
3. The Authorization Module shall コントローラで、操作の実行前に現在の利用者がその操作を許可されているかを判定できる
4. The Authorization Module shall ビューで、現在の利用者がその操作を許可されているかに応じて表示を切り替えられる
5. If 許可されていない操作を利用者が実行しようとする, then the Authorization Module shall 操作を実行せず、権限がないことを示す応答を返す
6. While 利用者がロールを 1 つも持たない状態でセッションが残っている, the Authorization Module shall その利用者にいかなる操作も許可しない
7. The Authorization Module shall 権限の定義を業務リソースごとの詳細な内容に依存させず、ロール数が少ない前提で単純に保つ

### Requirement 10: 権限なしの扱い
**Objective:** As a 利用者, I want 権限のない操作をしたときに何が起きたかが分かってほしい, so that 混乱せずに次の行動を選べる

#### Acceptance Criteria
1. If ログイン済みの利用者が許可されていない画面にアクセスする, then the Authorization Module shall 権限がない旨を示す画面または表示を返し、その画面の内容を表示しない
2. If ログイン済みの利用者が許可されていない操作を送信する, then the Authorization Module shall 操作の副作用を発生させない
3. The Authorization Module shall 権限なしの応答に、利用者のロールや権限定義の内部情報を含めない
4. If 未ログインの利用者が保護された画面にアクセスする, then the Authorization Module shall 権限なしの応答ではなく `entra-authentication` のログイン導線に委ねる

### Requirement 11: Entra ID 側設定手順の文書化
**Objective:** As a 運用者, I want Entra ID 側で必要な設定と事前確認の手順を参照したい, so that テナントを正しく設定して方式を選択できる

#### Acceptance Criteria
1. The Authorization Module shall roles クレーム方式に必要な Entra ID 側の前提（App Roles の定義、グループの割り当て、割り当て必須設定、ロール値とコード上のロール名の一致）を手順として文書化する
2. The Authorization Module shall groups クレーム方式に必要な Entra ID 側の前提（セキュリティグループの出力設定、グループ Object ID の対応表への登録）を手順として文書化する
3. The Authorization Module shall groups クレーム方式の制約（overage が発生する上限、所属グループ数が多い利用者は事前確認が必要であること）を文書化する
4. The Authorization Module shall roles クレーム方式ではグループの階層構造がロールに反映されないことを文書化する
5. The Authorization Module shall どちらの方式を選ぶかの判断基準（テナントの契約種別）を文書化する
6. The Authorization Module shall ロールの変更がログイン時にのみ反映されることと、反映の遅延の上限を文書化する

### Requirement 12: 秘密情報と機微情報の扱い
**Objective:** As a 運用者, I want ロール解決に関わる情報が意図せず露出しないでほしい, so that テナント内のグループ構成が漏れない

#### Acceptance Criteria
1. The Authorization Module shall ログや利用者向け表示に、groups クレームの全内容を出力しない
2. The Authorization Module shall 保存する情報を、コード上で定義されたロール名に限定する
3. The Authorization Module shall ロール導出に使用するクレームを、署名検証済みの ID token から取得したものに限る
