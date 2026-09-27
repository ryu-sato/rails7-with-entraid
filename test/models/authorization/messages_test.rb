require "test_helper"

class Authorization::MessagesTest < ActiveSupport::TestCase
  LOCALES = %i[en ja].freeze
  FORBIDDEN_KEYS = %w[title body back].freeze

  def all_messages
    LOCALES.flat_map do |locale|
      keys = Authorization::Result::REASONS.map { |reason| "authorization.rejections.#{reason}" } +
             FORBIDDEN_KEYS.map { |key| "authorization.forbidden.#{key}" }
      keys.map { |key| [ locale, key, I18n.t!(key, locale: locale) ] }
    end
  end

  test "every rejection reason has a message in every locale" do
    LOCALES.each do |locale|
      Authorization::Result::REASONS.each do |reason|
        message = I18n.t!("authorization.rejections.#{reason}", locale: locale)
        assert_kind_of String, message
        assert message.present?, "#{locale}: #{reason} is blank"
      end
    end
  end

  test "the forbidden screen texts exist in every locale" do
    LOCALES.each do |locale|
      FORBIDDEN_KEYS.each do |key|
        assert I18n.t!("authorization.forbidden.#{key}", locale: locale).present?, "#{locale}: #{key} is blank"
      end
    end
  end

  test "each rejection reason has its own wording" do
    LOCALES.each do |locale|
      texts = Authorization::Result::REASONS.map { |reason| I18n.t!("authorization.rejections.#{reason}", locale: locale) }
      assert_equal texts.uniq.size, texts.size, "#{locale}: two reasons share the same message"
    end
  end

  test "messages are fixed text with no interpolation" do
    all_messages.each do |locale, key, message|
      assert_no_match(/%\{|%<|<%/, message, "#{locale} #{key} must not interpolate")
    end
  end

  test "no message exposes internals: claims, tokens, identifiers or role names" do
    role_names = Role::NAMES.map { |name| /\b#{Regexp.escape(name)}\b/i }
    all_messages.each do |locale, key, message|
      assert_no_match(/claim|token|GUID|Object ID|\boid\b|\btid\b/i, message, "#{locale} #{key}")
      role_names.each { |pattern| assert_no_match(pattern, message, "#{locale} #{key} names a role") }
    end
  end

  test "no message is left as a missing translation" do
    all_messages.each do |locale, key, message|
      assert_no_match(/translation missing/i, message, "#{locale} #{key}")
    end
  end

  test "the two locales define the same keys" do
    en = I18n.t!("authorization", locale: :en)
    ja = I18n.t!("authorization", locale: :ja)
    assert_equal en.dig(:rejections).keys.sort, ja.dig(:rejections).keys.sort
    assert_equal en.dig(:forbidden).keys.sort, ja.dig(:forbidden).keys.sort
  end
end
