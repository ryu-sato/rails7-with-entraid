require "test_helper"
require "minitest/mock"
require "rack/session"
require "rack/test"

class EntraAuthAbsoluteTimeoutTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  LIMIT = 8.hours.to_i # Config default; ENTRA_SESSION_ABSOLUTE_HOURS is unset in tests

  # Minimal stand-in for Warden::Proxy: per-scope session hashes and a
  # logout recorder.
  class FakeWarden
    attr_reader :sessions, :logouts

    def initialize
      @sessions = Hash.new { |hash, scope| hash[scope] = {} }
      @logouts = []
    end

    def session(scope) = @sessions[scope]

    def logout(scope)
      @logouts << scope
      @sessions.delete(scope)
    end
  end

  setup do
    @saved_callbacks = Warden::Manager._after_set_user.dup
    @env_saved = ENV.delete("ENTRA_SESSION_ABSOLUTE_HOURS")
    @warden = FakeWarden.new
    freeze_time
    # Only the absolute timeout is under test here, not Devise's idle timeout.
    @saved_timeout_in = User.timeout_in
    User.timeout_in = 10.years
    RealStack.user = User.create!(tid: EntraAuth::Config.tenant_id, oid: SecureRandom.uuid, name: "alice")
  end

  teardown do
    User.timeout_in = @saved_timeout_in
    Warden::Manager._after_set_user.replace(@saved_callbacks)
    ENV["ENTRA_SESSION_ABSOLUTE_HOURS"] = @env_saved if @env_saved
  end

  def run_hook(event, scope: :user, warden: @warden)
    EntraAuth::AbsoluteTimeout.call(:user_record, warden, { event: event, scope: scope })
  end

  def login_at = @warden.session(:user)["login_at"]

  def caught(&block) = catch(:warden, &block)

  # --- recording (6.5) ---

  test ":authentication records the current time as an integer" do
    run_hook(:authentication)
    assert_equal Time.now.to_i, login_at
    assert_kind_of Integer, login_at
  end

  test ":set_user (test login helpers) records login_at and does not expire" do
    result = caught { run_hook(:set_user) }
    assert_nil result
    assert_equal Time.now.to_i, login_at
    assert_empty @warden.logouts
  end

  test "re-sign-in overwrites a stale login_at and restarts the clock (6.5)" do
    run_hook(:authentication)
    travel(LIMIT - 60)
    run_hook(:authentication)
    assert_equal Time.now.to_i, login_at

    travel(LIMIT - 1)
    assert_nil caught { run_hook(:fetch) }
    travel(2)
    assert_equal({ scope: :user, message: :absolute_timeout }, caught { run_hook(:fetch) })
  end

  test ":authentication with a stale login_at is not expired, only overwritten" do
    @warden.session(:user)["login_at"] = Time.now.to_i - LIMIT * 10
    assert_nil caught { run_hook(:authentication) }
    assert_equal Time.now.to_i, login_at
    assert_empty @warden.logouts
  end

  # --- :fetch checks (6.2, 6.4) ---

  test ":fetch just under the limit does not expire and leaves login_at alone" do
    @warden.session(:user)["login_at"] = Time.now.to_i - (LIMIT - 1)
    before = login_at
    assert_nil caught { run_hook(:fetch) }
    assert_equal before, login_at
    assert_empty @warden.logouts
  end

  test ":fetch exactly at the limit is still valid (expires only when strictly greater)" do
    @warden.session(:user)["login_at"] = Time.now.to_i - LIMIT
    assert_nil caught { run_hook(:fetch) }
    assert_empty @warden.logouts
  end

  test ":fetch one second over the limit logs out and throws :absolute_timeout" do
    @warden.session(:user)["login_at"] = Time.now.to_i - (LIMIT + 1)
    thrown = caught { run_hook(:fetch) }
    assert_equal({ scope: :user, message: :absolute_timeout }, thrown)
    assert_equal [ :user ], @warden.logouts
  end

  test ":fetch with a missing login_at expires" do
    thrown = caught { run_hook(:fetch) }
    assert_equal({ scope: :user, message: :absolute_timeout }, thrown)
    assert_equal [ :user ], @warden.logouts
  end

  test ":fetch uses the configured absolute timeout (6.6 via Config)" do
    ENV["ENTRA_SESSION_ABSOLUTE_HOURS"] = "1"
    @warden.session(:user)["login_at"] = Time.now.to_i - 3601
    assert_equal :absolute_timeout, caught { run_hook(:fetch) }[:message]
  end

  test "another scope's session is unaffected" do
    @warden.session(:admin)["login_at"] = Time.now.to_i
    @warden.session(:user)["login_at"] = Time.now.to_i - (LIMIT + 1)
    caught { run_hook(:fetch, scope: :user) }
    assert_equal [ :user ], @warden.logouts
    assert_equal Time.now.to_i, @warden.session(:admin)["login_at"]

    assert_nil caught { run_hook(:fetch, scope: :admin) }
  end

  test "idle activity never extends the limit: repeated :fetch does not write login_at" do
    run_hook(:authentication)
    origin = login_at
    5.times do
      travel(LIMIT / 10)
      assert_nil caught { run_hook(:fetch) }
      assert_equal origin, login_at
    end
    travel(LIMIT)
    assert_equal :absolute_timeout, caught { run_hook(:fetch) }[:message]
  end

  test "unknown events do nothing, even with a stale or missing login_at" do
    assert_nil caught { run_hook(:something_else) }
    assert_nil caught { run_hook(nil) }
    assert_empty @warden.logouts
    assert_empty @warden.sessions
  end

  # --- install! ---

  test "install! registers the hook once and is idempotent" do
    Warden::Manager._after_set_user.reject! { |callback, _| callback.equal?(EntraAuth::AbsoluteTimeout::HOOK) }
    count = -> { Warden::Manager._after_set_user.count { |callback, _| callback.equal?(EntraAuth::AbsoluteTimeout::HOOK) } }
    assert_equal 0, count.call

    assert_equal true, EntraAuth::AbsoluteTimeout.install!
    assert_equal false, EntraAuth::AbsoluteTimeout.install!
    assert_equal 1, count.call
    assert EntraAuth::AbsoluteTimeout.installed?
  end

  # --- through a real Warden::Manager / Proxy (Rack + cookie session) ---

  class RealStack
    include Rack::Test::Methods

    # Devise (mapped since the :user routes exist) serializes real records only.
    class << self
      attr_accessor :user
    end

    APP = lambda do |env|
      warden = env["warden"]
      case env["PATH_INFO"]
      when "/login"
        warden.set_user(RealStack.user, event: :authentication, scope: :user)
        [ 200, {}, [ "logged in" ] ]
      when "/test_login"
        warden.set_user(RealStack.user, scope: :user) # what sign_in / login_as does
        [ 200, {}, [ "test logged in" ] ]
      else
        user = warden.user(:user)
        user ? [ 200, {}, [ "hello #{user.name}" ] ] : [ 401, {}, [ "unauthenticated" ] ]
      end
    end

    FAILURE_APP = lambda do |env|
      message = env["warden.options"][:message]
      [ 401, {}, [ "failed #{message}" ] ]
    end

    def app
      @app ||= Rack::Builder.new do
        use Rack::Session::Cookie, secret: "x" * 64, same_site: :lax
        use Warden::Manager do |config|
          config.failure_app = FAILURE_APP
          config.default_scope = :user
        end
        run APP
      end.to_app
    end
  end

  test "real Warden stack: login, restore within limit, then absolute expiry with :absolute_timeout" do
    EntraAuth::AbsoluteTimeout.install!
    browser = RealStack.new

    browser.get "/login"
    assert_equal 200, browser.last_response.status

    travel(LIMIT / 2)
    browser.get "/me"
    assert_equal "hello alice", browser.last_response.body

    travel(LIMIT / 2) # exactly at the limit: still valid
    browser.get "/me"
    assert_equal "hello alice", browser.last_response.body

    travel(1)
    browser.get "/me"
    assert_equal 401, browser.last_response.status
    assert_equal "failed absolute_timeout", browser.last_response.body

    # the scope was logged out: no automatic revival
    browser.get "/me"
    assert_equal "failed ", browser.last_response.body # 401 without a message
  end

  test "real Warden stack: re-sign-in restarts the clock; set_user (test login) is not expired" do
    EntraAuth::AbsoluteTimeout.install!
    browser = RealStack.new

    browser.get "/login"
    travel(LIMIT - 10)
    browser.get "/login"
    travel(LIMIT - 10)
    browser.get "/me"
    assert_equal "hello alice", browser.last_response.body

    other = RealStack.new
    other.get "/test_login"
    other.get "/me"
    assert_equal "hello alice", other.last_response.body
  end
end
