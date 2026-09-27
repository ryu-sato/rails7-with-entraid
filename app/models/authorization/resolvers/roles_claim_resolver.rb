module Authorization
  module Resolvers
    # roles claim method: the App Role values assigned to the user (via the
    # enterprise application) arrive in the roles claim and are the candidates
    # as they are. Defined-role filtering and deduplication belong to RoleSync.
    #
    # Reads only the roles claim; the groups claim and any overage marker are
    # ignored, so this method never rejects a sign-in itself.
    class RolesClaimResolver
      # claims: Authorization::Claims -> Result::Candidates
      def call(claims)
        Result::Candidates.new(names: claims.roles)
      end
    end
  end
end
