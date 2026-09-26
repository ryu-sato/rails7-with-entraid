require "test_helper"
require "logger"
require "stringio"

class EntraAuthSignInGateTest < ActiveSupport::TestCase
  Gate = EntraAuth::SignInGate
  TID = "11111111-2222-3333-4444-555555555555".freeze
  OID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  FakeUser = Struct.new(:role, :saved)

  # 固定の汎用文言は、現在のロケールのキー（3.4 で定義）から解決される
  def generic_message
    I18n.t("entra_authentication.failures.generic")
  end

  def identity
    @identity ||= EntraAuth::VerifiedIdentity.from_auth_hash(
      OmniAuth::AuthHash.new(extra: { raw_info: { "oid" => OID, "tid" => TID, "name" => "Taro" } }),
      expected_tenant_id: TID
    )
  end

  def user
    @user ||= FakeUser.new(nil, false)
  end

  def capture_log
    original = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "no gates registered accepts (9.4)" do
    decision = Gate.evaluate(identity, user)
    assert decision.accepted?
    assert_not decision.rejected?
    assert_equal true, decision.accepted
  end

  test "accept and reject helpers build decisions" do
    accept = Gate.accept
    assert_kind_of Gate::Decision, accept
    assert accept.accepted?

    reject = Gate.reject(reason: :no_role, message: "権限がありません")
    assert reject.rejected?
    assert_equal :no_role, reject.reason
    assert_equal "権限がありません", reject.message
  end

  test "a single accepting gate accepts (9.2)" do
    Gate.register(->(_i, _u) { Gate.accept })
    assert Gate.evaluate(identity, user).accepted?
  end

  test "a rejecting gate carries reason and message unchanged (9.3)" do
    Gate.register(->(_i, _u) { Gate.reject(reason: :no_role, message: "ロールが割り当てられていません") })
    decision = Gate.evaluate(identity, user)
    assert decision.rejected?
    assert_equal :no_role, decision.reason
    assert_equal "ロールが割り当てられていません", decision.message
  end

  test "a rejection with a blank message gets the generic message" do
    Gate.register(->(_i, _u) { Gate.reject(reason: :no_role, message: "  ") })
    decision = Gate.evaluate(identity, user)
    assert decision.rejected?
    assert_equal :no_role, decision.reason
    assert_equal generic_message, decision.message
  end

  test "gates run in registration order and all accepting accepts" do
    calls = []
    Gate.register(->(_i, _u) { calls << :first; Gate.accept })
    Gate.register(->(_i, _u) { calls << :second; Gate.accept })
    Gate.register(->(_i, _u) { calls << :third; Gate.accept })
    assert Gate.evaluate(identity, user).accepted?
    assert_equal %i[first second third], calls
  end

  test "the first rejection short-circuits later gates" do
    calls = []
    Gate.register(->(_i, _u) { calls << :first; Gate.accept })
    Gate.register(->(_i, _u) { calls << :second; Gate.reject(reason: :second_no, message: "second") })
    Gate.register(->(_i, _u) { calls << :third; Gate.reject(reason: :third_no, message: "third") })
    decision = Gate.evaluate(identity, user)
    assert_equal :second_no, decision.reason
    assert_equal %i[first second], calls
  end

  test "a raising gate is rejected as gate_error with the generic message and never raises" do
    Gate.register(->(_i, _u) { raise "secret detail SENTINEL-MSG" })
    decision = nil
    log = capture_log { decision = Gate.evaluate(identity, user) }

    assert decision.rejected?
    assert_equal :gate_error, decision.reason
    assert_equal generic_message, decision.message
    assert_includes log, "RuntimeError"
    assert_includes log, "gate_error"
    assert_not_includes log, "SENTINEL-MSG"
    assert_not_includes log, OID
    assert_not_includes log, TID
    assert_not_includes log, "Taro"
  end

  test "a raising gate stops later gates" do
    later = false
    Gate.register(->(_i, _u) { raise ArgumentError, "boom" })
    Gate.register(->(_i, _u) { later = true; Gate.accept })
    assert_equal :gate_error, Gate.evaluate(identity, user).reason
    assert_not later
  end

  test "a non-Decision return fails closed as gate_error" do
    Gate.register(->(_i, _u) { true })
    decision = nil
    log = capture_log { decision = Gate.evaluate(identity, user) }
    assert decision.rejected?
    assert_equal :gate_error, decision.reason
    assert_equal generic_message, decision.message
    assert_includes log, "gate_error"
  end

  test "a nil return fails closed as gate_error" do
    Gate.register(->(_i, _u) { nil })
    assert_equal :gate_error, Gate.evaluate(identity, user).reason
  end

  test "register accepts procs and objects responding to call" do
    obj = Object.new
    def obj.call(_identity, _user) = EntraAuth::SignInGate.reject(reason: :obj, message: "obj")
    Gate.register(proc { |_i, _u| Gate.accept })
    Gate.register(obj)
    assert_equal :obj, Gate.evaluate(identity, user).reason
  end

  test "register rejects non-callables" do
    assert_raises(ArgumentError) { Gate.register("not callable") }
    assert_raises(ArgumentError) { Gate.register(nil) }
  end

  test "gates receive the same identity and user objects (9.1)" do
    seen = nil
    Gate.register(lambda { |i, u|
      seen = [ i, u ]
      Gate.accept
    })
    Gate.evaluate(identity, user)
    assert_same identity, seen[0]
    assert_same user, seen[1]
    assert_equal OID, seen[0].oid
    assert_equal TID, seen[0].tid
  end

  test "a gate may mutate the user and evaluate neither saves nor rolls back" do
    user.role = "old"
    Gate.register(lambda { |_i, u|
      u.role = "admin"
      Gate.reject(reason: :no_role, message: "no")
    })
    decision = Gate.evaluate(identity, user)
    assert decision.rejected?
    assert_equal "admin", user.role
    assert_equal false, user.saved
  end

  test "reset! clears registrations" do
    Gate.register(->(_i, _u) { Gate.reject(reason: :x, message: "x") })
    assert Gate.evaluate(identity, user).rejected?
    Gate.reset!
    assert Gate.evaluate(identity, user).accepted?
  end

  # The two tests below register a gate and assert none is left over from
  # the other one; the test_helper reset hook makes both pass in any order.
  test "registrations do not leak between tests (a)" do
    assert Gate.evaluate(identity, user).accepted?
    Gate.register(->(_i, _u) { Gate.reject(reason: :leak_a, message: "leak") })
    assert Gate.evaluate(identity, user).rejected?
  end

  test "registrations do not leak between tests (b)" do
    assert Gate.evaluate(identity, user).accepted?
    Gate.register(->(_i, _u) { Gate.reject(reason: :leak_b, message: "leak") })
    assert Gate.evaluate(identity, user).rejected?
  end

  test "the lib file does not reference app classes" do
    source = File.read(Rails.root.join("lib/entra_auth/sign_in_gate.rb"))
    code = source.lines.reject { |l| l.strip.start_with?("#") }.join
    assert_no_match(/\bUser\b/, code)
    assert_no_match(/VerifiedIdentity|EntraAuth::Config/, code)
  end
end
