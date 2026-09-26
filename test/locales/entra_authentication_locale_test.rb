require "test_helper"
require "yaml"

# Task 3.4: fixed end-user messages (ja / en) for session expiry and sign-in
# failure. Requirements 4.4, 6.4.
class EntraAuthenticationLocaleTest < ActiveSupport::TestCase
  LOCALE_FILES = {
    ja: Rails.root.join("config/locales/entra_authentication.ja.yml"),
    en: Rails.root.join("config/locales/entra_authentication.en.yml")
  }.freeze

  KEYS = %w[
    devise.failure.timeout
    devise.failure.absolute_timeout
    devise.failure.unauthenticated
    entra_authentication.failures.cancelled
    entra_authentication.failures.failed
    entra_authentication.failures.generic
    entra_authentication.failures.rejected
  ].freeze

  # Words that would indicate internal information leaking into a message.
  DENY_WORDS = /\b(tenant|client|secret|token|exception|claims?|oid|tid|groups?|issuer|nonce|stack|trace)\b/i
  DENY_JA = /テナント|クライアント|シークレット|トークン|例外|クレーム|グループ|エラーコード/

  test "locale files exist and are valid UTF-8 YAML" do
    LOCALE_FILES.each do |locale, path|
      assert path.exist?, "#{path} must exist"
      content = File.binread(path).force_encoding(Encoding::UTF_8)
      assert content.valid_encoding?, "#{path} must be valid UTF-8"
      data = YAML.safe_load(content)
      assert_equal [ locale.to_s ], data.keys
    end
  end

  test "every key resolves in both locales" do
    LOCALE_FILES.each_key do |locale|
      KEYS.each do |key|
        value = I18n.t(key, locale: locale, raise: true)
        assert_kind_of String, value, "#{locale}:#{key}"
      end
    end
  end

  test "ja and en define identical key sets" do
    ja = owned_keys(:ja)
    en = owned_keys(:en)
    assert_equal ja.sort, en.sort
    assert_equal KEYS.sort, ja.sort
  end

  test "messages are non-blank, static and free of interpolation" do
    LOCALE_FILES.each_key do |locale|
      KEYS.each do |key|
        msg = I18n.t(key, locale: locale, raise: true)
        assert_not_predicate msg.strip, :empty?, "#{locale}:#{key} blank"
        assert_not_includes msg, "%{", "#{locale}:#{key} interpolates"
        assert_not_includes msg, "%<", "#{locale}:#{key} interpolates"
      end
    end
  end

  test "messages do not mention internal details" do
    LOCALE_FILES.each_key do |locale|
      KEYS.each do |key|
        msg = I18n.t(key, locale: locale, raise: true)
        assert_no_match DENY_WORDS, msg, "#{locale}:#{key}"
        assert_no_match DENY_JA, msg, "#{locale}:#{key}"
      end
    end
  end

  test "idle and absolute expiry messages differ" do
    LOCALE_FILES.each_key do |locale|
      assert_not_equal I18n.t("devise.failure.timeout", locale: locale),
                       I18n.t("devise.failure.absolute_timeout", locale: locale)
    end
  end

  test "cancelled and failed messages differ" do
    LOCALE_FILES.each_key do |locale|
      assert_not_equal I18n.t("entra_authentication.failures.cancelled", locale: locale),
                       I18n.t("entra_authentication.failures.failed", locale: locale)
    end
  end

  test "SignInGate generic message equals the locale text (ja)" do
    raising = ->(_identity, _user) { raise "boom" }
    EntraAuth::SignInGate.reset!
    EntraAuth::SignInGate.register(raising)
    decision = I18n.with_locale(:ja) { EntraAuth::SignInGate.evaluate(nil, nil) }
    assert_equal I18n.t("entra_authentication.failures.generic", locale: :ja, raise: true), decision.message
  ensure
    EntraAuth::SignInGate.reset!
  end

  test "SignInGate inline default equals the ja text" do
    default = EntraAuth::SignInGate.const_get(:GENERIC_FAILURE_DEFAULT)
    assert_equal default, I18n.t("entra_authentication.failures.generic", locale: :ja, raise: true)
  end

  test "YAML loads through the I18n backend without errors" do
    I18n.backend.send(:init_translations)
    assert I18n.backend.initialized?
  end

  test "app default locale is unchanged" do
    assert_equal :en, I18n.default_locale
  end

  private

  def owned_keys(locale)
    data = YAML.safe_load_file(LOCALE_FILES.fetch(locale)).fetch(locale.to_s)
    flatten(data).select { |k| k.start_with?("entra_authentication.", "devise.failure.") }
  end

  def flatten(hash, prefix = nil)
    hash.flat_map do |k, v|
      key = [ prefix, k ].compact.join(".")
      v.is_a?(Hash) ? flatten(v, key) : [ key ]
    end
  end
end
