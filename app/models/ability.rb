# What each role may do, in one place (cancancan).
#
# A user's stored roles are narrowed to the roles still defined in code before
# anything is granted, so a role removed from Role::NAMES stops working even if
# it remains in the database. With no user, or no valid role, nothing is allowed.
# Permissions are additive: a user with several roles gets the union.
#
# One private <role>_rules method per entry in Role::NAMES (a test enforces
# this). Keep them small; rules for real business resources are added by the
# domain features that introduce those resources.
class Ability
  include CanCan::Ability

  def initialize(user)
    return if user.nil?

    Role.known(user.roles).each { |role| __send__("#{role}_rules") }
  end

  private

  # Provisional rules, until the first domain feature defines real resources.
  def admin_rules
    can :manage, :all
  end

  def member_rules
    can :read, :all
  end
end
