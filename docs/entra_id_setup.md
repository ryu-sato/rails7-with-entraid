# Entra ID 認証の設定・運用手順書

運用者向けの手順書です。Entra ID（Microsoft Entra ID、単一テナント）でアプリ登録を行い、このアプリに設定を渡し、実機で動作を確認するまでの手順をまとめています。設定の一覧はコード（`lib/entra_auth/config.rb`）と一致させており、`test/docs/entra_id_setup_doc_test.rb` が食い違いを検出します。

## 1. 概要

- 認証方式は OpenID Connect の認可コードフロー（PKCE / S256、`state` / `nonce` 検証）です。接続先は **単一テナントの Entra ID v2.0** のみで、`common` / `organizations` / `consumers` のような複数テナント共通のエンドポイントは受け付けません。
- サインインの開始は `POST /users/auth/openid_connect`（CSRF トークン付き）、Entra ID からの戻り先は `/users/auth/openid_connect/callback` です。ほかに `GET /login`（サインイン画面）、`DELETE /logout`（サインアウト）、`GET /signed_out`（サインアウト後の画面）があります。
- ID token / Access token は保存しません。利用者の識別には ID token の `oid`（利用者）と `tid`（テナント）を使います。
- ロール・グループ・「割り当てが必要」（ユーザー割り当ての要否）による認可は、別仕様 `entra-authorization` の範囲です。この手順書では扱いません。

## 2. 前提

- Entra ID テナントで、アプリ登録を作成できる権限（アプリケーション管理者など）があること。
- このアプリの公開 URL（例: `https://app.example.com`）が決まっていること。以降 `<ENTRA_APP_BASE_URL>` と書きます。
- 本番は HTTPS を使うこと（http のスキームも設定上は通りますが、ローカル開発用です）。

### 画面の文言とロケール

このアプリの既定のロケール（`I18n.default_locale`）は `en` です（`set_locale` や `default_locale` の設定はコードにありません）。したがって、何も設定を変えなければ、利用者には英語の文言が表示されます。この手順書が引用する日本語の文言は `ja` ロケールのものです。日本語で表示したい場合は、アプリの設定に `config.i18n.default_locale = :ja` を加える方法があります（この手順書ではコードを変更しません）。文言は `config/locales/` の `sessions.*.yml` / `entra_authentication.*.yml` / `home.*.yml`（`ja` と `en`）にあります。

チェックリスト（8 章）とトラブルシューティング（10 章）で見る主な文言は次のとおりです。

| ロケールのキー | ja | en |
| --- | --- | --- |
| `sessions.unavailable.title` | 現在サインインできません | Sign-in is temporarily unavailable |
| `entra_authentication.failures.cancelled` | サインインがキャンセルされました。もう一度お試しいただけます。 | Sign-in was cancelled. You can try again. |
| `entra_authentication.failures.failed` | サインインに失敗しました。しばらくしてからもう一度お試しいただくか、管理者にお問い合わせください。 | Sign-in failed. Please try again later or contact the administrator. |
| `devise.failure.timeout` | しばらく操作がなかったため、セッションの有効期限が切れました。もう一度サインインしてください。 | Your session expired because of inactivity. Please sign in again. |
| `devise.failure.absolute_timeout` | セッションの最大継続時間に達したため、有効期限が切れました。もう一度サインインしてください。 | Your session expired because the maximum session duration was reached. Please sign in again. |

以降、文言は `ja` の表記で書き、括弧内のキーで上の表と対応させます。

## 3. Entra ID 側のアプリ登録の手順

1. **アプリを登録する**: Entra 管理センターの「アプリの登録」で「新規登録」を選び、サポートされるアカウントの種類は **「この組織ディレクトリのみに含まれるアカウント」（単一テナント）** にします。
2. **リダイレクト URI（サインイン後の戻り先）**: 「認証」でプラットフォーム **「Web」** を追加し、次を **完全一致** で登録します。

   ```
   <ENTRA_APP_BASE_URL>/users/auth/openid_connect/callback
   ```

   スキーム・ホスト・ポート・パス・末尾のスラッシュの有無が 1 文字でも違うと、サインインが `AADSTS50011`（リダイレクト URI の不一致）で失敗します。
3. **サインアウト後のリダイレクト URI**: 次も、同じ「Web」のリダイレクト URI として登録します。

   ```
   <ENTRA_APP_BASE_URL>/signed_out
   ```

   Entra ID がコールバック以外の URI を `post_logout_redirect_uri` として受理するかは、公式文書だけでは確認できていません（未確認）。安全側で必ず登録し、8 章のチェックリストで実機確認してください。
4. **クライアントシークレット**: 「証明書とシークレット」で新しいクライアントシークレットを作成し、**値**（「シークレット ID」ではありません）をその場で控えます。値は作成直後にしか表示されません。有効期限が切れるとサインインできなくなる（`AADSTS7000215` など）ため、期限と更新の予定を運用カレンダーに登録してください。
5. **トークンのバージョンを v2.0 にする**: 「マニフェスト」で `accessTokenAcceptedVersion`（`api.requestedAccessTokenVersion`）を `2` にします。このアプリは ID token の発行元（`iss`）が v2.0 の形式（`https://login.microsoftonline.com/<テナント ID>/v2.0`）であることを要求し、異なる `iss` のトークンは拒否します。そのため 2 を推奨します（この設定を v1.0 のままにすると ID token の `iss` が変わるかどうかは、実機で未確認です）。
6. **オプションクレーム `login_hint`（ID token）**: 「トークン構成」で「オプションの要求を追加」→ トークンの種類「ID」→ `login_hint` を追加します。サインアウト時に `logout_hint` としてアカウントを特定し、アカウント選択画面を出さないために使います。ID token にこのクレームを追加できるかは、実機で未確認です（8 章で確認）。クレームがなくてもサインインとサインアウトは動きますが、サインアウト時にアカウント選択画面が出ます（縮退動作。5 章参照）。
7. **そのほか**: 暗黙的な許可（Implicit grant）は **不要** です（有効にしません）。要求するスコープは `openid` / `profile` / `email` のみです。API のアクセス許可の追加や管理者の同意は要りません。
8. **控える値**: 「概要」の「ディレクトリ（テナント）ID」と「アプリケーション（クライアント）ID」を控えます。

## 4. アプリ側の設定（環境変数・credentials）

設定は環境変数を優先し、なければ `Rails.application.credentials.entra_id` の同名のキーを使います。値が空（空白のみを含む）の環境変数は未設定として扱われ、credentials へ進みます。設定は呼び出しのたびに読まれます（ただしセッション寿命は下記のとおり起動時に固定されます）。

| 環境変数 | credentials.entra_id のキー | 必須 | 説明 |
| --- | --- | --- | --- |
| `ENTRA_TENANT_ID` | `tenant_id` | 必須 | ディレクトリ（テナント）ID。**GUID のみ**。`common` / `organizations` / `consumers` やドメイン名は不正として拒否します |
| `ENTRA_CLIENT_ID` | `client_id` | 必須 | アプリケーション（クライアント）ID |
| `ENTRA_CLIENT_SECRET` | `client_secret` | 必須 | クライアントシークレットの値。ログ・画面には出しません |
| `ENTRA_APP_BASE_URL` | `app_base_url` | 必須 | このアプリの公開 URL。http(s) の URL で、クエリ・フラグメントは不可。末尾のスラッシュは取り除かれます。リダイレクト URI とサインアウト後の URI はこの値から組み立てられます |
| `ENTRA_SESSION_IDLE_MINUTES` | `idle_minutes` | 任意 | 無操作でセッションが切れるまでの分数（正の整数）。既定値 30 |
| `ENTRA_SESSION_ABSOLUTE_HOURS` | `absolute_hours` | 任意 | サインインからセッションが強制的に切れるまでの時間数（正の整数）。既定値 8 |

- 起動時の検証エラーとサーバーログには、次の **項目名** が出ます。環境変数・credentials のキーとの対応は次のとおりです（寿命の 2 項目だけ、項目名が credentials のキーと異なります）。

  | 項目名（エラー・ログ） | 環境変数 | credentials.entra_id のキー |
  | --- | --- | --- |
  | `tenant_id` | `ENTRA_TENANT_ID` | `tenant_id` |
  | `client_id` | `ENTRA_CLIENT_ID` | `client_id` |
  | `client_secret` | `ENTRA_CLIENT_SECRET` | `client_secret` |
  | `app_base_url` | `ENTRA_APP_BASE_URL` | `app_base_url` |
  | `idle_timeout` | `ENTRA_SESSION_IDLE_MINUTES` | `idle_minutes` |
  | `absolute_timeout` | `ENTRA_SESSION_ABSOLUTE_HOURS` | `absolute_hours` |

- 寿命の 2 項目に正の整数以外を入れると、その項目は既定値で動作し、起動時の検証（下記）では不正な項目として報告されます。
- credentials の設定例（`bin/rails credentials:edit`。環境ごとの credentials を使う場合は `--environment production` を付けます）:

  ```yaml
  entra_id:
    tenant_id: 00000000-0000-0000-0000-000000000000
    client_id: 00000000-0000-0000-0000-000000000000
    client_secret: (シークレットの値)
    app_base_url: https://app.example.com
    idle_minutes: 30
    absolute_hours: 8
  ```

### 起動時の検証と本番コマンドの注意

- 本番（`RAILS_ENV=production`）では、起動時に設定を検証し、不足・不正があると **起動に失敗** します。エラーには項目名だけが出て、値は出ません（例: `Invalid Entra ID configuration: tenant_id, client_secret`）。
- そのため、本番で Rails を起動するワンオフのコマンド（`bin/rails db:migrate`、`bin/rails console`、`bin/rails runner` など）も、`ENTRA_*`（または credentials）が設定されていないと失敗します。
- 例外は `SECRET_KEY_BASE_DUMMY=1` を付けた場合で、この検証を省略します。これは **アセットのビルド専用** です（`Dockerfile` は `SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile` を使います）。実際の運用コマンドには付けないでください。
- `bin/docker-entrypoint` の `db:prepare` は実行時に走るため、コンテナに実際の設定が渡っていれば問題ありません。
- 起動後に設定が不正な状態になった場合（起動後に設定を書き換えた場合など）、`/login` は利用者向けの汎用画面（HTTP 503、「現在サインインできません」= `sessions.unavailable.title`。英語では “Sign-in is temporarily unavailable”）を返し、サーバーログに不正な項目名だけを出します（`Entra ID configuration is invalid: ...`）。
- **セッション寿命（`ENTRA_SESSION_IDLE_MINUTES`）の変更は再起動が必要** です（起動時に固定されます）。

## 5. サインアウトの挙動と制約

- サインアウトは `DELETE /logout` のみです（GET では実行できません）。アプリ側のセッションを先に終了し、そのあと Entra ID のサインアウトエンドポイントへ 303 でリダイレクトします。アプリ側のサインアウトは Entra ID の状態に依存しません。
- Entra ID へ渡すパラメータは `post_logout_redirect_uri` と（あれば）`logout_hint` だけです。**`id_token_hint` / `state` / `client_id` は送りません**。`logout_hint` は ID token の `login_hint` クレームから得ます。`login_hint` がないとアカウント選択画面が出ることがあります（縮退動作）。
- サインアウトすると、サーバー側で `users.session_token` を再発行するため、**その利用者の全ブラウザ・全 Cookie のセッションが無効** になります（別のブラウザでサインイン中でも終了します。意図した挙動です）。サインアウト前に控えられた Cookie も使えなくなります。
- セッションがすでに失効している（無操作または絶対時間）状態でのサインアウトは、ログイン画面へ戻り失効のメッセージを表示するだけで、Entra ID のサインアウトには進まず、**Entra ID の SSO セッションは終了しません**。また `session_token` も再発行されません（残余リスク）。古い Cookie は、無操作と絶対時間の上限で有界（最長でサインインから `ENTRA_SESSION_ABSOLUTE_HOURS` 時間）です。
- サインアウト用の URL は設定だけから決まり（通信も discovery もしません）、組み立てられないのは設定が不完全・不正なとき（`tenant_id` が GUID でない、`app_base_url` が不正または未設定）だけです。その場合は、アプリ側のサインアウトのあと `/signed_out` を表示します（Entra ID には行きません）。Entra ID やネットワークの状態には依存しません。
- フロントチャネルログアウト・バックチャネルログアウト（Entra ID 側で別のアプリからサインアウトしたときにこのアプリのセッションを終了する機能）は **対応していません**。

## 6. セッション寿命

- 無操作の失効: 最後の操作から `ENTRA_SESSION_IDLE_MINUTES`（既定 30 分）。操作のたびに更新されます。
- 絶対時間の失効: サインインから `ENTRA_SESSION_ABSOLUTE_HOURS`（既定 8 時間）。操作しても延長されません。ちょうどの時刻は有効で、超過すると失効します。
- 失効すると、次のリクエストでログイン画面へ転送され、失効の理由（無操作 / 最大継続時間）のメッセージが表示されます。サインイン前に開こうとしたページ（クエリを含む）は、サインイン後に復帰します。
- セッションは Rails の暗号化・署名済み Cookie に入ります。Cookie のサイズは約 4KB が上限です。ID token / Access token は保存しないので、この上限には通常余裕があります。
- 無操作の設定は起動時に固定されるため、変更するときは再起動してください。

## 7. 運用上の注意

- **開発環境でサインイン操作をしない**: 開発環境でも、サインイン開始のリクエストは実際の `login.microsoftonline.com` へ通信します。テストスイートは通信を遮断し、スタブだけで動きます。実 Entra ID との確認は 8 章の手順で、テナントを決めて行ってください。
- **CSRF と HTTP メソッド**: サインイン開始は POST + CSRF トークン、サインアウトは DELETE のみです。GET でサインイン開始・サインアウトはできません。
- **ログ**: ログには秘密情報（クライアントシークレット、認可コード、`state`、`nonce`、ID token、`login_hint`、`session_token`）やクレームの本体、IdP / 例外のメッセージを出しません。失敗の診断は、失敗のキー・例外のクラス名・設定不備の項目名だけです（10 章参照）。SQL の DEBUG ログにはユーザーの name / email / `oid` が出るため、本番のログレベルは INFO（既定）以上にしてください。
- **クライアントシークレットの更新**: 期限前に新しいシークレットを作成し、環境変数（または credentials）を差し替えて再起動し、動作確認後に古いシークレットを削除します。
- **未対応**: 認可（ロール・グループ・割り当て）、フロントチャネル / バックチャネルログアウト、複数テナント、Remember me（「ログイン状態を保持する」機能は提供しません）。
- **既知のフォローアップ（サインインの失敗処理の細部。最終検証で扱う）**: コールバックの広い例外処理が、データベースエラーなどもログだけに落とすこと、`form_post` を使う場合はコールバックの CSRF 除外が必要になること。

## 8. 実機確認チェックリスト

**自動テストはすべてスタブで動き、実際の Entra ID とは通信しません。以下は実テナントで運用者が手動で確認します。** 本番で確認する場合は、専用のテスト用アカウントを使ってください。トークンやクレームの本体を確認するための一時的な出力コード（クレームビューアなど）を本番に入れてはいけません。クレームの有無は、Entra 管理センターの設定と、サインインの成否・サインアウトの動きから判断します。

- [ ] サインインに成功し、開こうとしていた元のページ（クエリを含む）に戻る
- [ ] ID token に `oid` と `tid` が含まれる（含まれないとサインインは失敗します。Entra 管理センターの「トークン構成」と、サインインの成否で確認）
- [ ] ID token に `login_hint` が含まれる（「トークン構成」で ID token のオプションクレームとして追加済みであること。含まれるかは、下のサインアウト時にアカウント選択画面が出ないことで確認）
- [ ] サインアウトで Entra ID が `post_logout_redirect_uri` を受理し、`<ENTRA_APP_BASE_URL>/signed_out` に戻る（エラーで止まる場合は 3 章の 3. の登録を確認）
- [ ] `login_hint` が有効なとき、サインアウトでアカウント選択画面が **出ない**（無効にした場合は出る。これは縮退動作で、サインアウト自体は成立します）
- [ ] サーバーが Entra ID のサインアウト URL に `id_token_hint` / `state` / `client_id` を **付けていない**（ブラウザのアドレスバーまたは開発者ツールのネットワークで、`post_logout_redirect_uri` と `logout_hint` のみであることを確認）
- [ ] Entra ID のサインイン画面でキャンセルすると、「サインインがキャンセルされました」（`entra_authentication.failures.cancelled`。英語では “Sign-in was cancelled. You can try again.”）の文言でログイン画面に戻る
- [ ] 別テナントのアカウントでのサインインが拒否される（単一テナントの登録では、通常は Entra ID 自身がトークンをアプリへ渡す前に拒否します（例: `AADSTS50020`）。アプリの `tid` / `iss` の照合は多層防御で、この場合は固定の失敗文言（`entra_authentication.failures.failed`。英語では “Sign-in failed. Please try again later or contact the administrator.”）が表示され、セッションが作られません）
- [ ] 無操作の失効が設定どおりに動く（テスト環境で `ENTRA_SESSION_IDLE_MINUTES` を短く（例: 1）して再起動し、放置後の操作でログイン画面へ転送され、無操作の文言（`devise.failure.timeout`。英語では “Your session expired because of inactivity. Please sign in again.”）が出る）
- [ ] 絶対時間の失効が設定どおりに動く（テスト環境で `ENTRA_SESSION_ABSOLUTE_HOURS` を 1 にし、操作を続けていても 1 時間後に失効して最大継続時間の文言（`devise.failure.absolute_timeout`。英語では “Your session expired because the maximum session duration was reached. Please sign in again.”）が出る）
- [ ] サインアウト後のセッション無効化: 2 つのブラウザで同じ利用者でサインインし、一方でサインアウトしたあと、もう一方の操作でログイン画面へ転送される
- [ ] 期限切れのセッションでのサインアウトは、ログイン画面へ戻るだけで Entra ID のサインアウトに進まない（5 章の制約どおり）

## 9. セキュリティの要点

- サインインの開始は POST + CSRF トークン、サインアウトは DELETE のみ。外部へのリダイレクトはサインアウト時の Entra ID のサインアウト URL の 1 か所だけで、URL はコードが固定のホストと GUID のテナントから組み立てます（利用者の入力は使いません）。
- ID token の発行元（`iss`）・宛先・署名・期限・`nonce`・`state`・PKCE を検証し、`tid` も設定のテナントと照合します。
- セッションは暗号化・署名済みの Cookie で、ID token / Access token は保存しません。
- クライアントシークレットは環境変数または credentials に置き、リポジトリやログ・画面に出しません。

## 10. トラブルシューティング

サインインの失敗時、利用者には固定の文言（「サインインに失敗しました…」= `entra_authentication.failures.failed`、または「キャンセルされました」= `entra_authentication.failures.cancelled`。英語の文言は 2 章の表）だけが出ます。原因はサーバーログで確認します。ログの次の行には、**キー・理由の種別・クラス名しか出ません**（メッセージ・値は出しません）。

- `[Users::OmniauthCallbacks] failure key=<キー> error=<例外クラス名>`（認証の失敗）
- `[Users::OmniauthCallbacks] invalid identity reason=<理由>`（`oid` / `tid` の欠落・`tid` の不一致など、ID token のクレームの不備）
- `[Users::OmniauthCallbacks] sign-in rejected reason=<理由>`（認可ゲートによる拒否）
- `[Users::OmniauthCallbacks] sign-in error class=<例外クラス名>`（想定外の例外）
- `[EntraAuth::SignInGate] reason=gate_error ...`（認可ゲートの例外）
- `Authentication failure! <キー>: <例外クラス名>`（OmniAuth の失敗ログ）
- `Session token rotation failed: <例外クラス名>`（サインアウト時のセッション無効化の失敗。アプリ側のサインアウト自体は行われます）

| 症状 | 考えられる原因と確認 |
| --- | --- |
| `/login` が「現在サインインできません」（503。英語では “Sign-in is temporarily unavailable”） | 設定の不足・不正。ログの `Entra ID configuration is invalid: <項目名>` を見て、4 章の設定を直す |
| 本番の起動・`db:migrate`・console が `Invalid Entra ID configuration: ...` で失敗 | 4 章の設定不足。ワンオフのコマンドにも `ENTRA_*` が必要（`SECRET_KEY_BASE_DUMMY=1` はアセットのビルド専用） |
| サインインで固定の失敗文言、ログのキーが `invalid_id_token` | `iss` の不一致（`accessTokenAcceptedVersion` が 2 でない）、テナント ID の誤り、別テナントのアカウント（単一テナントの登録では通常 Entra ID 自身が `AADSTS50020` などで先に拒否するため、アプリの `tid` / `iss` の照合は多層防御）、`nonce` / 署名 / 期限の不正。3 章の 5. とテナント ID を確認 |
| Entra ID の画面に `AADSTS50011`（リダイレクト URI の不一致） | 登録した Web のリダイレクト URI と `<ENTRA_APP_BASE_URL>/users/auth/openid_connect/callback` が 1 文字でも違う（スキーム、ホスト、ポート、末尾のスラッシュ）。`ENTRA_APP_BASE_URL` も見直す |
| サインイン後に固定の失敗文言、ログのキーが `invalid_client` などの token エンドポイントのエラー（Entra ID の画面・ネットワークでは `AADSTS7000215` = シークレットの誤り、`AADSTS7000222` = 期限切れ（未検証）） | クライアントシークレットの値の誤り（「シークレット ID」を設定した）、または期限切れ。新しい値を作成して差し替え、再起動 |
| ログのキーが `discovery_failed` | Entra ID の設定ドキュメント / 鍵の取得に失敗。テナント ID の誤り、サーバーからの外向き通信（`login.microsoftonline.com`）の遮断を確認 |
| ログのキーが `timeout` / `failed_to_connect` | token エンドポイントへの通信の遅延・失敗。ネットワーク・プロキシを確認 |
| ログのキーが `csrf_detected` | `state` の不一致。サインイン開始から戻るまでに Cookie が失われた（ブラウザの Cookie 設定、複数タブ、サインイン画面の放置、`ENTRA_APP_BASE_URL` のホストと実際のアクセス先が違う） |
| ログのキーが `invalid_configuration` | サインイン開始時の設定不備（外部通信の前に失敗させています）。4 章の設定を確認 |
| ログのキーが `access_denied` | Entra ID の画面でキャンセルされた、または拒否された（利用者には「キャンセルされました」が出る。英語では “Sign-in was cancelled. You can try again.”） |
| サインイン後にログイン画面へ戻され、固定の失敗文言が出る（`failure key=` の行がない場合） | ログの `invalid identity reason=` / `sign-in rejected reason=` / `gate_error`（ID token のクレームの不備、または別仕様の認可ゲートの拒否）を確認する |
| サインアウトでアカウント選択画面が出る | `login_hint` のオプションクレームが未設定（3 章の 6.）。サインアウトは成立している（縮退動作） |
| サインアウトで Entra ID がエラーを出す | サインアウト後のリダイレクト URI（`<ENTRA_APP_BASE_URL>/signed_out`）が未登録（3 章の 3.）、または `ENTRA_APP_BASE_URL` の不一致 |
| 期限切れ後にサインアウトしても Entra ID の SSO が続いている | 5 章の制約どおり（失効済みのセッションのサインアウトは Entra ID に進まない）。必要なら利用者が Entra ID 側で直接サインアウトする |
| 寿命の設定を変えても反映されない | 起動時に固定される。再起動する |

## 11. 設定ライブラリの読み込み（開発者向け）

- `lib/entra_auth/` は Zeitwerk の管理外です。`config/application.rb` の `config.autoload_lib(ignore: %w[assets tasks entra_auth])` で自動読み込みから除外しています。
- `lib/entra_auth.rb` が、`lib/entra_auth/*.rb` をファイル名の昇順にすべて `require` します。この `lib/entra_auth.rb` は `config/initializers/devise.rb`（先頭で `require "entra_auth"`）と `config/initializers/entra_auth.rb` から読み込みます。
- 理由: Devise の initializer が起動中に `EntraAuth::Strategy` を参照します。この initializer は `entra_auth.rb` より先に走り、そのときは自動読み込みがまだ使えないため、明示的に読み込みます。
- 影響: (1) `lib/entra_auth/` の変更にはサーバーの再起動が必要です（コードのリロードの対象外）。(2) 読み込み順がファイル名順のため、このディレクトリのファイルは、ファイルの先頭やクラス本体の直下で、他の `EntraAuth` の定数を参照してはいけません（メソッドの中でのみ参照します）。
