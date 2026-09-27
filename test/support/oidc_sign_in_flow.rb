# Drives the real sign-in flow (GET /login -> POST start -> stubbed IdP -> callback)
# through the actual OmniAuth strategy, Devise and SignInGate. The IdP is the
# WebMock OidcProviderStub, so nothing reaches a real host. Same approach as
# test/integration/sign_in_flow_test.rb (entra-authentication).
#
#   class MyTest < ActionDispatch::IntegrationTest
#     include OidcSignInFlow
#   end
#
# Setup also registers the gate the app registers at boot (roles are checked).
module OidcSignInFlow
  START_PATH = "/users/auth/openid_connect".freeze
  CALLBACK_PATH = "/users/auth/openid_connect/callback".freeze

  def self.included(base)
    base.include AuthorizationGate
    base.setup do
      install_oidc_provider_stub
      register_authorization_gate
      @oid = SecureRandom.uuid
      @saved_forgery = ActionController::Base.allow_forgery_protection
      @saved_test_mode = OmniAuth.config.test_mode
      OmniAuth.config.test_mode = false
      ActionController::Base.allow_forgery_protection = true
    end
    base.teardown do
      ActionController::Base.allow_forgery_protection = @saved_forgery
      OmniAuth.config.test_mode = @saved_test_mode
    end
  end

  def form_token(html)
    Nokogiri::HTML(html).at_css("form input[name=authenticity_token]")&.[]("value")
  end

  # Returns { state:, nonce: } parsed from the (never followed) authorization redirect.
  def start_flow
    get "/login"
    assert_response :success
    post START_PATH, params: { authenticity_token: form_token(response.body) }
    assert_response :redirect
    assert response.location.start_with?(oidc_stub.authorization_endpoint), response.location
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    { state: query["state"], nonce: query["nonce"] }
  end

  # Start + callback. claims are merged over the defaults of the ID token.
  def complete_flow(claims: {})
    started = start_flow
    base = { oid: @oid, name: "Test User", email: "test.user@example.com", nonce: started[:nonce] }
    oidc_stub.token_response_id_token = oidc_stub.id_token(**base.merge(claims))
    get CALLBACK_PATH, params: { code: "test-auth-code", state: started[:state] }
  end

  def assert_signed_in
    assert_response :see_other
    assert_redirected_to root_url
    follow_redirect!
    assert_response :success
  end

  # Back on the login page with +message+, and no session: protected pages redirect.
  def assert_refused_at_login(message)
    assert_response :redirect
    assert_redirected_to new_user_session_url
    follow_redirect!
    assert_response :success
    assert_includes response.body, ERB::Util.html_escape(message)
    assert_select "form[action='#{START_PATH}']" # the user can try again
    get "/"
    assert_redirected_to new_user_session_url
  end

  def captured_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
