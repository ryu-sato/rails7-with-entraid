module EntraAuth
  # Sign-in fields extracted from a verified authentication result.
  #
  # Built only from auth.extra.raw_info (the verified ID token claims). Never
  # reads auth.credentials, and holds neither the access token nor the raw ID
  # token string.
  #
  # Identity decision: (tid, oid) is the unique key of a user. Both are stored
  # trimmed and lowercased, so differing GUID case can never create a second
  # identity (the users table columns are plain strings, case-sensitive).
  # name, email and login_hint are optional and never used for identification.
  #
  # LOAD-ORDER: this file must not reference other EntraAuth constants at load
  # time; the expected tenant is passed in as a method argument.
  VerifiedIdentity = Data.define(:oid, :tid, :name, :email, :login_hint, :claims)

  class VerifiedIdentity
    # Raised by from_auth_hash. reason is :missing_claims or :tenant_mismatch.
    # The message contains the reason only, never a claim value.
    class Invalid < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason.to_sym
        super("Verified identity rejected: #{@reason}")
      end
    end

    def self.from_auth_hash(auth, expected_tenant_id:)
      raw = auth&.extra&.raw_info
      raise Invalid, :missing_claims unless raw.respond_to?(:to_h) && !raw.is_a?(String)

      claims = deep_freeze(normalize(raw.to_h))
      oid = guid(claims["oid"])
      tid = guid(claims["tid"])
      raise Invalid, :missing_claims if oid.nil? || tid.nil?
      raise Invalid, :tenant_mismatch unless tid == guid(expected_tenant_id)

      new(
        oid: oid, tid: tid,
        name: optional(claims["name"]), email: optional(claims["email"]),
        login_hint: optional(claims["login_hint"]), claims: claims
      )
    end

    # Trimmed, lowercased String or nil when blank / not a String.
    def self.guid(value)
      optional(value)&.downcase&.freeze
    end
    private_class_method :guid

    def self.optional(value)
      return nil unless value.is_a?(String)

      stripped = value.strip
      stripped.empty? ? nil : stripped.freeze
    end
    private_class_method :optional

    # Plain Hash / Array copy with String keys (caller's data is untouched).
    def self.normalize(value)
      case value
      when Hash then value.to_h { |k, v| [ k.to_s, normalize(v) ] }
      when Array then value.map { |v| normalize(v) }
      when String then value.dup
      else value
      end
    end
    private_class_method :normalize

    def self.deep_freeze(value)
      case value
      when Hash then value.each { |k, v| k.freeze; deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end
    private_class_method :deep_freeze
  end
end
