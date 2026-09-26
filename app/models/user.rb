class User < ApplicationRecord
  devise :omniauthable, :timeoutable, omniauth_providers: [ :openid_connect ]

  validates :tid, :oid, presence: true

  # Finds the user for a verified Entra identity by (tid, oid), creating it on
  # first sign-in. name/email are display-only mirrors of the latest claims
  # (nil included) and are never used to identify a person.
  # A concurrent create hits the unique index; we then re-fetch the winner.
  def self.from_identity(identity)
    attempts = 0
    begin
      user = find_by(tid: identity.tid, oid: identity.oid) || new(tid: identity.tid, oid: identity.oid)
      user.assign_attributes(name: identity.name, email: identity.email)
      user.save! if user.changed?
      user
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 3
      raise
    end
  end
end
