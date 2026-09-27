require "test_helper"
require "minitest/mock"

# Task 5.5: log hygiene through the REAL stack (real EntraAuth::Strategy against
# the WebMock OidcProviderStub; no OmniAuth test mode, no network).
#
# Every scenario captures BOTH Rails.logger (broadcast, so the request line, the
# controller / gate lines and the ActionController / ActiveRecord subscribers are
# all included) and OmniAuth.logger (a separate logger that writes to STDOUT by
# default), and asserts on the combined text: no secret, token, state / nonce /
# code, hint, session token, claim value or exception / IdP message; the safe
# diagnostics (failure key, exception class, gate reason, config item names)
# must be present.
#
# Capture level: INFO, mirroring production (config.log_level defaults to
# "info", asserted below). ActiveRecord logs SQL (with name / email / oid values
# on INSERT / UPDATE) only at DEBUG, which production does not emit.
# Requirements 4.3, 4.4, 8.2.
class LogHygieneTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  START = "/users/auth/openid_connect".freeze
  CALLBACK = "/users/auth/openid_connect/callback".freeze
  CLIENT_SECRET = "test-client-secret".freeze # set by test_helper
  SENTINEL_DESC = "SENTINEL-DESC-AADSTS-77 secret-ish".freeze
  SENTINEL_URI = "https://sentinel-uri.example.test/err".freeze
  SENTINEL_TOKEN_ERROR = "AADSTS-SENTINEL-99 secret-ish".freeze
  SENTINEL_NAME = "SENTINEL-NAME".freeze
  SENTINEL_EMAIL = "sentinel@example.test".freeze
  SENTINEL_CODE = "sentinel-auth-code-5-5".freeze
  SENTINEL_HINT = "sentinel-login-hint-5-5".freeze
  SENTINEL_EXCEPTION = "SENTINEL-EXCEPTION-MESSAGE-55".freeze
  SENTINEL_GATE_NAME = "SENTINEL-GATE-NAME".freeze
  SENTINEL_GATE_MESSAGE = "SENTINEL-GATE-REJECT-MESSAGE".freeze
  ACCESS_TOKEN = "test-access-token".freeze # returned by OidcProviderStub

  setup do
    install_oidc_provider_stub
    @oid = SecureRandom.uuid
    @forbidden = [ CLIENT_SECRET, SENTINEL_NAME, SENTINEL_EMAIL, SENTINEL_CODE, SENTINEL_DESC, SENTINEL_URI,
                   SENTINEL_TOKEN_ERROR, SENTINEL_EXCEPTION, SENTINEL_GATE_NAME, SENTINEL_GATE_MESSAGE,
                   SENTINEL_HINT, ACCESS_TOKEN, @oid ]
    @saved_forgery = ActionController::Base.allow_forgery_protection
    @saved_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @saved_forgery
    OmniAuth.config.test_mode = @saved_test_mode
  end

  # --- helpers ---

  # Runs the block and returns the combined Rails + OmniAuth log text (INFO).
  def capture_logs
    rails_io = StringIO.new
    omniauth_io = StringIO.new
    rails_capture = ActiveSupport::Logger.new(rails_io, level: Logger::INFO)
    saved_omniauth_logger = OmniAuth.config.logger
    OmniAuth.config.logger = Logger.new(omniauth_io, level: Logger::DEBUG)
    Rails.logger.broadcast_to(rails_capture)
    begin
      yield
    ensure
      Rails.logger.stop_broadcasting_to(rails_capture)
      OmniAuth.config.logger = saved_omniauth_logger
    end
    "#{rails_io.string}\n#{omniauth_io.string}"
  end

  def start_flow
    get "/login"
    assert_response :success
    post START, params: { authenticity_token: form_token(response.body) }
    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    @forbidden.push(query["state"], query["nonce"])
    { state: query["state"], nonce: query["nonce"] }
  end

  def complete_flow(claims: {}, callback_state: nil, nonce: nil, code: SENTINEL_CODE)
    started = start_flow
    base = { oid: @oid, name: SENTINEL_NAME, email: SENTINEL_EMAIL, nonce: nonce || started[:nonce] }
    oidc_stub.token_response_id_token = oidc_stub.id_token(**base.merge(claims))
    @forbidden << oidc_stub.token_response_id_token
    get CALLBACK, params: { code: code, state: callback_state || started[:state] }
  end

  def assert_clean(log)
    assert log.present?, "the log capture is empty (capture is not working)"
    assert_no_match(/eyJ[A-Za-z0-9_-]{5,}/, log, "JWT-like text in the log")
    # OmniAuth's failure line is "<key>: <Class>" only; ", <message>" must never follow.
    assert_no_match(/Authentication failure! \S+: \S+,/, log, "exception message in the OmniAuth failure line")
    @forbidden.compact.each { |secret| assert_not_includes log, secret, "log leaked #{secret.inspect}" }
  end

  def assert_signed_out
    get "/"
    assert_redirected_to new_user_session_url
  end

  # A failure through the real strategy: key + class from OmniAuth and from our
  # controller, nothing else.
  def assert_failure_log(log, key:, klass:)
    assert_includes log, "Authentication failure! #{key}: #{klass}"
    assert_match(/failure key=#{key} error=#{Regexp.escape(klass)}\b/, log)
  end

  def user_record = User.find_by!(oid: @oid)

  # --- environment assumptions ---

  test "production logs at info by default (SQL with claim values is debug-only)" do
    source = Rails.root.join("config/environments/production.rb").read
    assert_match(/config\.log_level\s*=\s*ENV\.fetch\("RAILS_LOG_LEVEL",\s*"info"\)/, source)
  end

  test "OmniAuth logger is separate from Rails.logger (so it is captured on its own)" do
    assert_not_same OmniAuth.logger, Rails.logger
  end

  # --- filter_parameters ---

  test "filter_parameters masks OAuth / OIDC values and leaves unrelated names alone" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    %w[code state nonce id_token access_token client_secret login_hint error_description error_uri].each do |name|
      assert_equal "[FILTERED]", filter.filter(name => "value")[name], "#{name} must be filtered"
    end
    %w[zipcode estate barcode errors error].each do |name|
      assert_equal "value", filter.filter(name => "value")[name], "#{name} must not be filtered"
    end
  end

  # --- success ---

  test "successful sign-in logs no secret, token, claim or hint" do
    log = capture_logs { complete_flow(claims: { login_hint: SENTINEL_HINT }) }
    assert_redirected_to root_url
    assert_clean log
    assert_includes log, "Started GET \"#{CALLBACK}?"
    assert_includes log, "state=[FILTERED]"
    assert_includes log, "code=[FILTERED]"
  end

  # --- IdP-side failures ---

  test "user cancel: error_description / error_uri are filtered; key and class are logged" do
    started = start_flow
    log = capture_logs do
      get CALLBACK, params: { error: "access_denied", error_description: SENTINEL_DESC, error_uri: SENTINEL_URI,
                              state: started[:state] }
    end
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_failure_log log, key: "access_denied", klass: "OmniAuth::Strategies::OpenIDConnect::CallbackError"
    assert_includes log, "error_description=[FILTERED]"
  end

  test "an IdP-controlled error key cannot forge log lines" do
    started = start_flow
    log = capture_logs do
      get CALLBACK, params: { error: "evil\nFORGED-LINE-55 secret", state: started[:state] }
    end
    assert_clean log
    assert_no_match(/^FORGED-LINE-55/, log)
  end

  test "token endpoint error with a sentinel body: key and class only" do
    started = start_flow
    WebMock.stub_request(:post, oidc_stub.token_endpoint)
           .to_return(status: 400, headers: { "Content-Type" => "application/json" },
                      body: { error: "invalid_grant", error_description: SENTINEL_TOKEN_ERROR }.to_json)
    log = capture_logs { get CALLBACK, params: { code: SENTINEL_CODE, state: started[:state] } }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_match(/Authentication failure! invalid_grant: \S+/, log)
    assert_match(/failure key=invalid_grant error=\S+/, log)
  end

  test "token endpoint error without a body: key and class only" do
    started = start_flow
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_return(status: 500, body: "SENTINEL-EXCEPTION-MESSAGE-55")
    log = capture_logs { get CALLBACK, params: { code: SENTINEL_CODE, state: started[:state] } }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_match(/Authentication failure! \S+: \S+/, log)
  end

  # --- ID token failures ---

  test "ID token failures (issuer, audience, expiry, nonce, tenant, state) log key and class only" do
    past = Time.now.to_i - 7200
    {
      "issuer" => { claims: { iss: "https://login.microsoftonline.com/evil/v2.0" } },
      "audience" => { claims: { aud: "some-other-client" } },
      "expiry" => { claims: { iat: past - 60, nbf: past - 60, exp: past } },
      "nonce" => { nonce: "not-the-issued-nonce" },
      "missing oid" => { claims: { oid: nil } },
      "tenant mismatch" => { claims: { tid: "99999999-8888-7777-6666-555555555555" } }
    }.each do |label, flow|
      log = capture_logs { complete_flow(**flow) }
      assert_redirected_to new_user_session_url, label
      assert_clean log
      assert_match(/failure key=(invalid_id_token|callback_error) error=\S+/, log, label) unless label =~ /tenant|oid/
      assert_signed_out
    end
  end

  test "invalid ID token failure logs the key :invalid_id_token and the exception class" do
    log = capture_logs { complete_flow(claims: { aud: "some-other-client" }) }
    assert_clean log
    assert_failure_log log, key: "invalid_id_token", klass: "OpenIDConnect::ResponseObject::IdToken::InvalidAudience"
  end

  test "invalid signature logs key and class only" do
    started = start_flow
    forged_key = OpenSSL::PKey::RSA.generate(2048)
    jwt = JSON::JWT.new(oidc_stub.default_claims.merge(oid: @oid, name: SENTINEL_NAME, email: SENTINEL_EMAIL,
                                                        nonce: started[:nonce]))
    jwt.kid = oidc_stub.kid
    oidc_stub.token_response_id_token = jwt.sign(forged_key, :RS256).to_s
    @forbidden << oidc_stub.token_response_id_token
    log = capture_logs { get CALLBACK, params: { code: SENTINEL_CODE, state: started[:state] } }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_match(/failure key=invalid_id_token error=\S+/, log)
  end

  test "tenant mismatch logs the rejection reason only" do
    log = capture_logs { complete_flow(claims: { tid: "99999999-8888-7777-6666-555555555555" }) }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_includes log, "reason=tenant_mismatch"
    assert_not_includes log, "99999999-8888-7777-6666-555555555555"
  end

  # --- gate ---

  test "gate rejection with sentinel data in the user record logs the reason only" do
    EntraAuth::SignInGate.register(lambda { |_identity, user|
      user.update!(name: SENTINEL_GATE_NAME)
      EntraAuth::SignInGate.reject(reason: :not_allowed, message: SENTINEL_GATE_MESSAGE)
    })
    log = capture_logs { complete_flow }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_includes log, "sign-in rejected reason=not_allowed"
    assert_equal SENTINEL_GATE_NAME, user_record.name
  end

  test "gate that raises a sentinel message logs the class and reason only" do
    EntraAuth::SignInGate.register(->(_identity, _user) { raise SENTINEL_EXCEPTION })
    log = capture_logs { complete_flow }
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_includes log, "reason=gate_error cause=RuntimeError"
    assert_includes log, "sign-in rejected reason=gate_error"
  end

  # --- configuration failure ---

  test "start with an incomplete configuration logs the failure key only (no config values)" do
    get "/login"
    token = form_token(response.body)
    log = capture_logs do
      with_entra_env("ENTRA_CLIENT_SECRET" => nil, "ENTRA_TENANT_ID" => "sentinel-tenant-55") do
        post START, params: { authenticity_token: token }
      end
    end
    assert_redirected_to new_user_session_url
    assert_clean log
    assert_not_includes log, "sentinel-tenant-55"
    assert_includes log, "Authentication failure! invalid_configuration"
    assert_match(/failure key=invalid_configuration error=none/, log)
  end

  test "SessionsController#new 503 logs the item names only" do
    log = capture_logs do
      with_entra_env("ENTRA_CLIENT_SECRET" => "sentinel-secret-55", "ENTRA_TENANT_ID" => nil) { get "/login" }
    end
    assert_response :service_unavailable
    assert_clean log
    assert_not_includes log, "sentinel-secret-55"
    assert_includes log, "Entra ID configuration is invalid: tenant_id"
  end

  # --- sign-out ---

  test "sign-out logs no logout_hint or session token (also not in the redirect line)" do
    complete_flow(claims: { login_hint: SENTINEL_HINT })
    @forbidden << user_record.session_token
    token = meta_token(get_body("/"))
    log = capture_logs { delete "/logout", params: { authenticity_token: token } }
    assert_response :see_other
    assert_includes response.location, SENTINEL_HINT, "the hint must still reach the Entra sign-out URL"
    assert_clean log
    assert_signed_out
  end

  test "sign-out rotation failure logs the class only" do
    complete_flow(claims: { login_hint: SENTINEL_HINT })
    token = meta_token(get_body("/"))
    original = User.instance_method(:rotate_session_token!)
    User.send(:define_method, :rotate_session_token!) { raise ActiveRecord::StatementInvalid, SENTINEL_EXCEPTION }
    log = nil
    begin
      log = capture_logs { delete "/logout", params: { authenticity_token: token } }
    ensure
      User.send(:define_method, :rotate_session_token!, original)
    end
    assert_response :see_other
    assert_clean log
    assert_includes log, "Session token rotation failed: ActiveRecord::StatementInvalid"
  end

  def get_body(path)
    get path
    assert_response :success
    response.body
  end

  # --- static: no debugging leftovers, known set of log calls ---

  test "no puts / pp / p debugging in app, lib or config, and log calls are confined to known files" do
    files = Dir[Rails.root.join("{app,lib,config}/**/*.rb")].reject { |f| f.include?("/config/environments/") }
    debug_calls = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        "#{file.delete_prefix("#{Rails.root}/")}:#{i + 1}" if line =~ /(^|[^\w.])(puts|pp|p)[ (]/ && line !~ /^\s*#/
      end
    end
    assert_empty debug_calls
    loggers = files.select { |f| File.readlines(f).grep_v(/^\s*#/).join.match?(/\blogger\b|Rails\.error/) }.map { |f| f.delete_prefix("#{Rails.root}/") }
    assert_equal %w[
      app/controllers/sessions_controller.rb
      app/controllers/users/omniauth_callbacks_controller.rb
      lib/entra_auth/sign_in_gate.rb
    ].sort, loggers.sort
  end
end
