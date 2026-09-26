# Requirements Document

## Project Description (Input)
組織の Entra ID アカウントでアプリにサインインしたい利用者と、それを実装する開発チームがいる。現状は `rails new` 直後の雛形で認証がなく、誰でもアクセスできる。アプリ独自のパスワードやアカウントのライフサイクルを持たず、ID 管理を Entra ID に委譲した認証基盤に変える。

### 目指す状態
- 未ログインのユーザーが Entra ID でサインインでき、ログイン状態が Devise のセッションで管理される
- Entra ID のユーザーが `oid` + `tid` で一意に特定され、`User` レコードと対応付けられる
- 無操作タイムアウトとログインからの絶対時間上限でセッションが失効する
- ログアウト時に Entra ID 側のセッションも終了する（RP-Initiated Logout）

### アプローチ（discovery で決定済み）
- Devise（`omniauthable`, `timeoutable`）に omniauth_openid_connect を strategy として登録する
- Authorization Code Flow + PKCE（`discovery: true`, `response_type: :code`, `pkce: true`）。Access token は破棄する
- シングルテナントのエンドポイントを使い、`issuer` はテナント固有の v2.0 issuer（完全一致で検証）とする
- omniauth-rails_csrf_protection を導入し、ログイン開始は POST（`button_to`）で行う
- セッション寿命は Timeoutable と独自の絶対時間上限で制御し、Rememberable は使わない
- RP-Initiated Logout は gem 標準が `id_token_hint` を使わないため、Devise の sign-out 経路で自前実装する

### スコープ外
- roles / groups クレームの解釈、ロール保存、権限判定（`entra-authorization`）
- Front-channel Logout / Back-channel Logout
- Access token を使った API 呼び出し

詳細は `brief.md` を参照。

## Introduction
本仕様は、組織の Entra ID アカウントによるアプリへのサインイン・セッション管理・サインアウトを定める。アプリ独自のパスワードやアカウント管理は持たず、本人確認は Entra ID に委譲する。ロール取得と権限判定は `entra-authorization` が扱い、本仕様は「誰であるか」を確定してセッションを維持する範囲に限定する。

## Boundary Context
- **In scope**:
  - Entra ID による単一テナントのサインイン
  - 認証結果の検証
  - Entra ID ユーザーの一意な特定とアプリ内ユーザーへの対応付け
  - 未認証アクセスの保護
  - セッションの失効（無操作・絶対時間）
  - サインアウト（Entra ID 側セッションの終了を含む）
  - 運用者向けの設定と手順の文書化
- **Out of scope**:
  - ロール・グループの取得、保存、権限判定、ロール未保持や overage 時の拒否（`entra-authorization`）
  - Front-channel Logout、Back-channel Logout
  - 「ログイン状態を保持する」機能（Remember me）
  - Entra ID 以外の認証手段（パスワード認証など）
  - Access token を使った外部 API 呼び出し
- **Adjacent expectations**:
  - `entra-authorization` は、サインイン完了前に検証済みの認証情報を受け取ってサインインを受理または拒否できることを前提とする。本仕様はその受け渡しの機会を提供し、拒否の判定内容は持たない
  - Entra ID 側のアプリ登録（リダイレクト URI、サインアウト後のリダイレクト URI、トークンのバージョン、クライアントシークレット）は運用者が用意する。本仕様は必要な設定項目と手順を明示する
  - 業務機能は、サインイン済みユーザーを参照できることを前提とする

## Requirements

### Requirement 1: Entra ID によるサインイン
**Objective:** As a 組織の利用者, I want 自分の Entra ID アカウントでサインインしたい, so that アプリ用の別のパスワードを管理せずに利用できる

#### Acceptance Criteria
1. When 未サインインの利用者がサインインを開始する操作を行う, the Authentication Service shall 利用者を Entra ID のサインイン画面へ遷移させる
2. When Entra ID での本人確認が成功して認証結果が返却される, the Authentication Service shall 認証結果の検証（Requirement 2）を経てサインイン済みセッションを開始し、利用者が当初アクセスしようとしていたページ（なければトップページ）へ遷移させる
3. The Authentication Service shall サインインの開始を、アプリ内の正規の画面操作（POST 送信）からの要求に限定する
4. The Authentication Service shall アプリ独自のパスワードによるサインイン手段を提供しない
5. While 利用者がサインイン済みである, the Authentication Service shall サインイン開始の操作を再度求めずに、その利用者として各ページの要求を処理する

### Requirement 2: 認証結果の検証
**Objective:** As a 運用者, I want 想定した Entra ID テナントが発行した正当な認証結果だけを受け入れたい, so that なりすましや他テナントのユーザーによるサインインを防げる

#### Acceptance Criteria
1. When Entra ID から認証結果が返却される, the Authentication Service shall その認証結果が設定済みの単一テナントの発行元から、設定済みのこのアプリ宛てに発行されたものであることを検証する
2. When Entra ID から認証結果が返却される, the Authentication Service shall 認証結果の署名と有効期限を検証する
3. When Entra ID から認証結果が返却される, the Authentication Service shall その認証結果が、同じブラウザで開始したサインイン要求に対応するものであることを検証する
4. If 認証結果が検証のいずれかに失敗する, then the Authentication Service shall サインイン済みセッションを開始しない
5. If 認証結果が設定済みのテナント以外のユーザーに対するものである, then the Authentication Service shall サインイン済みセッションを開始しない
6. The Authentication Service shall Entra ID から得られるアクセス用の資格情報（Access token）を、サインインの完了後に保持も利用もしない

### Requirement 3: ユーザーの一意な特定
**Objective:** As a 開発チーム, I want Entra ID 上のユーザーをアプリ内で一意かつ不変に特定したい, so that 氏名やメールアドレスが変わっても同一人物として扱える

#### Acceptance Criteria
1. When 検証済みの認証結果が返却される, the Authentication Service shall Entra ID のユーザーのオブジェクト ID とテナント ID の組でアプリ内ユーザーを特定する
2. When 検証済みの認証結果のユーザーに対応するアプリ内ユーザーが存在しない, the Authentication Service shall そのユーザーを新規に作成してサインイン済みとする
3. When 検証済みの認証結果のユーザーに対応するアプリ内ユーザーが既に存在する, the Authentication Service shall 新規作成せずに既存のユーザーとしてサインイン済みとする
4. The Authentication Service shall メールアドレスや表示名などの変更されうる属性を、ユーザーの特定に用いない
5. The Authentication Service shall 同じオブジェクト ID とテナント ID の組に対して、アプリ内ユーザーを複数作成しない
6. While 同じユーザーが同時に複数回サインインを完了する, the Authentication Service shall アプリ内ユーザーを重複して作成しない

### Requirement 4: サインイン失敗時の対応
**Objective:** As a 組織の利用者, I want サインインできなかったときに状況が分かりたい, so that 再試行するか管理者に問い合わせるか判断できる

#### Acceptance Criteria
1. If 利用者が Entra ID のサインイン画面で操作を取り消す, then the Authentication Service shall サインイン済みセッションを開始せず、サインインをやり直せる画面へ案内する
2. If Entra ID がエラーを返す、または認証結果の検証に失敗する, then the Authentication Service shall サインインに失敗したことを利用者に通知し、サインインをやり直せる画面へ案内する
3. If サインインが失敗する, then the Authentication Service shall 失敗の原因を運用者が追跡できる形で記録する
4. The Authentication Service shall サインイン失敗の通知に、内部の設定値・秘密情報・認証結果の内容を含めない
5. If サインインを受理するかどうかを判断する後続の処理が、サインインを拒否する, then the Authentication Service shall サインイン済みセッションを開始しない

### Requirement 5: 未認証アクセスの保護
**Objective:** As a 運用者, I want サインインしていない利用者がアプリの機能に到達できないようにしたい, so that 組織外・未認証の利用を防げる

#### Acceptance Criteria
1. When 未サインインの利用者が保護対象のページにアクセスする, the Authentication Service shall そのページの内容を返さず、サインインを開始できる画面へ誘導する
2. When 未サインインの利用者が保護対象のページへの要求をサインインへ誘導される, the Authentication Service shall 元のページの場所を記憶し、サインイン成功後にそのページへ戻す
3. The Authentication Service shall 既定でアプリ内のすべてのページを保護対象とする
4. Where 特定のページが公開ページとして明示的に指定されている, the Authentication Service shall そのページをサインインなしで表示する
5. The Authentication Service shall サインイン画面およびサインインの完了・失敗の受け口を、サインイン前の利用者が到達できる状態に保つ

### Requirement 6: セッションの失効
**Objective:** As a 運用者, I want サインイン状態の有効期間を制限したい, so that 放置された端末や長期間同じセッションを使い続けることによるリスクを抑えられる

#### Acceptance Criteria
1. While 利用者のサインイン済みセッションで、設定された無操作時間を超えて要求がない, the Authentication Service shall そのセッションを失効させる
2. While 利用者のサインイン済みセッションが、サインイン完了時刻から設定された絶対時間を超えている, the Authentication Service shall 直前の操作時刻にかかわらずそのセッションを失効させる
3. When セッションが失効した利用者が保護対象のページにアクセスする, the Authentication Service shall そのページの内容を返さず、再サインインを促す
4. When 失効したセッションの利用者が再サインインを促される, the Authentication Service shall セッションが失効したことを利用者に分かる形で通知する
5. When 利用者が再サインインを完了する, the Authentication Service shall 絶対時間の起点をその再サインインの完了時刻に更新する
6. The Authentication Service shall 無操作時間と絶対時間を、コードの変更なしに運用者が設定できるようにする
7. The Authentication Service shall ブラウザを閉じた後もサインイン状態を保持する仕組み（Remember me）を提供しない

### Requirement 7: サインアウト
**Objective:** As a 組織の利用者, I want サインアウトしたときに Entra ID 側のサインイン状態も終了させたい, so that 共用端末で他の人が自分のアカウントで再利用できないようにできる

#### Acceptance Criteria
1. When サインイン済みの利用者がサインアウトを行う, the Authentication Service shall アプリのセッションを直ちに終了させる
2. When サインイン済みの利用者がサインアウトを行う, the Authentication Service shall 利用者を Entra ID のサインアウト処理へ遷移させて Entra ID 側のセッションも終了させる
3. When サインアウトを行う利用者の Entra ID 側のセッションが特定できる, the Authentication Service shall サインアウトするアカウントを Entra ID に対して明示し、アカウントの選択を求められないようにする
4. When Entra ID 側のサインアウトが完了する, the Authentication Service shall 利用者をアプリのサインアウト完了後の画面へ戻す
5. If Entra ID のサインアウト処理へ遷移できない、または Entra ID 側の処理が完了しない, then the Authentication Service shall アプリ側のセッションを終了済みの状態に保つ
6. When サインアウトが完了した後に、その利用者が保護対象のページへアクセスする, the Authentication Service shall そのページの内容を返さず、サインインを促す
7. The Authentication Service shall サインアウトの実行を、アプリ内の正規の画面操作からの要求に限定する

### Requirement 8: 運用設定と機密情報の取り扱い
**Objective:** As a 運用者, I want Entra ID との接続設定を環境ごとに安全に管理したい, so that 秘密情報が漏れず、設定ミスにも早く気付ける

#### Acceptance Criteria
1. The Authentication Service shall テナント、クライアント識別子、クライアントシークレット、およびサインイン後・サインアウト後の戻り先を、コードに直接書かず環境ごとの設定から取得する
2. The Authentication Service shall クライアントシークレットなどの秘密情報を、ソースコード、ログ、利用者向けの画面に出力しない
3. If サインインに必要な Entra ID の接続設定が不足している、または不正である, then the Authentication Service shall 起動時、または最初のサインイン操作時に設定の問題を運用者が識別できる形で報告する
4. The Authentication Service shall 単一テナントの Entra ID のみを接続先として扱い、複数テナントに共通のエンドポイントを受け入れない
5. The Authentication Service shall Entra ID 側のアプリ登録に必要な設定（リダイレクト URI、サインアウト後のリダイレクト URI、トークンのバージョン、クライアントシークレット）とその手順を、運用者が参照できる文書として提供する

### Requirement 9: 後続の認可処理との接続
**Objective:** As a 開発チーム, I want サインインの完了前に、後続の処理が検証済みの認証情報を使ってサインインの可否を判断できるようにしたい, so that ロールに基づくログイン拒否を認証基盤に手を入れずに追加できる

#### Acceptance Criteria
1. When 認証結果の検証が成功する, the Authentication Service shall 検証済みの認証結果の内容を、サインイン済みセッションを開始する前に後続のサインイン処理から参照できるようにする
2. When 後続のサインイン処理がサインインを受理する, the Authentication Service shall サインイン済みセッションを開始する
3. When 後続のサインイン処理がサインインを拒否する, the Authentication Service shall サインイン済みセッションを開始せず、拒否の理由を利用者に通知できるようにする
4. Where 後続のサインイン処理が何も設定されていない, the Authentication Service shall 検証に成功した認証結果をそのまま受理する
5. The Authentication Service shall ロール、グループ、権限に関する判定を自ら行わない
