module Authorization
  # Outcomes passed between the resolvers, RoleSync and the sign-in gate adapter.
  module Result
    # Why a sign-in is refused because of roles. Each has its own user-facing
    # message (authorization.rejections.<reason>).
    REASONS = %i[no_roles groups_overage].freeze

    # What a resolver found in the claims, before the common rules apply.
    # names: Array[String] (may contain undefined roles or duplicates)
    Candidates = Data.define(:names)

    # Roles were derived and stored. roles: non-empty Array[String] of defined roles.
    Synced = Data.define(:roles) do
      def initialize(roles:)
        raise ArgumentError, "roles must not be empty" if roles.empty?

        super
      end
    end

    # The sign-in must be refused. reason: one of REASONS.
    Rejected = Data.define(:reason) do
      def initialize(reason:)
        raise ArgumentError, "unknown rejection reason" unless REASONS.include?(reason)

        super
      end
    end
  end
end
