module Authorization
  module Resolvers
    # groups claim method: group Object IDs (GUIDs) in the groups claim are
    # translated to role names through a configured map. Defined-role filtering
    # and deduplication belong to RoleSync.
    #
    # Overage (too many groups for the token, so "groups" is replaced by
    # _claim_names / _claim_sources) is decided first and refuses the sign-in:
    # the groups cannot be known without calling Microsoft Graph, which this
    # method never does. It makes no network call at all.
    #
    # Reads only the groups claim and the overage marker; the roles claim is ignored.
    class GroupsClaimResolver
      # group_role_map: { "<group object id>" => "<role name>" }; keys are
      # compared case-insensitively.
      def initialize(group_role_map:)
        @group_role_map = group_role_map.to_h { |guid, role| [ guid.to_s.downcase, role.to_s ] }.freeze
      end

      # claims: Authorization::Claims -> Result::Candidates | Result::Rejected
      def call(claims)
        return Result::Rejected.new(reason: :groups_overage) if claims.groups_overage?

        Result::Candidates.new(names: claims.groups.filter_map { |guid| @group_role_map[guid.downcase] })
      end
    end
  end
end
