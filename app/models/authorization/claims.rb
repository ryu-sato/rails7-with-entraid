module Authorization
  # The only view of the ID token claims that role resolution may use.
  #
  # Built from auth.extra.raw_info (in authentication: identity.claims). That hash
  # merges the userinfo response with the ID token claims (ID token wins), so
  # nothing outside roles / groups / _claim_names is read: those keys are not part
  # of the userinfo response, which keeps role resolution on verified ID token
  # claims. Nothing else is retained, and inspect / to_s never reveal contents.
  class Claims
    # raw_info: a Hash-like with string keys (Hashie::Mash from OmniAuth) or
    # symbol keys. Anything that is not a Hash gives empty claims.
    def self.from_raw_info(raw_info)
      source = raw_info.is_a?(Hash) ? raw_info.with_indifferent_access : {}
      new(
        roles: string_list(source["roles"]),
        groups: string_list(source["groups"]),
        groups_overage: overage?(source["_claim_names"])
      )
    end

    def self.string_list(value)
      value.is_a?(Array) ? value.grep(String).freeze : [].freeze
    end
    private_class_method :string_list

    # Entra ID replaces "groups" with _claim_names / _claim_sources when the user
    # belongs to too many groups (overage). _claim_names then names "groups".
    def self.overage?(claim_names)
      claim_names.is_a?(Hash) && claim_names.key?("groups")
    end
    private_class_method :overage?

    private_class_method :new

    attr_reader :roles, :groups

    def initialize(roles:, groups:, groups_overage:)
      @roles = roles
      @groups = groups
      @groups_overage = groups_overage
    end

    def groups_overage?
      @groups_overage
    end

    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end
    alias_method :to_s, :inspect
  end
end
