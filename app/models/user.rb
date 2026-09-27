class User < ApplicationRecord
  devise :omniauthable, :timeoutable, omniauth_providers: [ :openid_connect ]

  validates :tid, :oid, presence: true

  # Server-side session invalidation (task 4.4). The token is Devise's
  # authenticatable_salt: the session cookie stores [id, token] and Devise
  # restores the user only while the token still matches. Rotating it at
  # sign-out therefore kills every cookie issued earlier, including copies.
  # All browsers of one user share ONE token (it is not rotated at sign-in),
  # so signing out in any browser ends the sessions in all of them (intended).
  # The value is never logged: :token in filter_parameters masks it in
  # inspect and request logs.
  has_secure_token :session_token

  def authenticatable_salt
    session_token
  end

  def rotate_session_token!
    regenerate_session_token
  end

  # Finds the user for a verified Entra identity by (tid, oid), creating it on
  # first sign-in. name/email are display-only mirrors of the latest claims
  # (nil included) and are never used to identify a person.
  # A concurrent create hits the unique index; we then re-fetch the winner.
  def self.from_identity(identity)
    attempts = 0
    begin
      user = find_by(tid: identity.tid, oid: identity.oid) || new(tid: identity.tid, oid: identity.oid)
      user.assign_attributes(name: identity.name, email: identity.email)
      # Legacy rows created before the column existed: issue a token before sign-in.
      user.session_token = User.generate_unique_secure_token if user.session_token.blank?
      user.save! if user.changed?
      user
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts < 3
      raise
    end
  end
end
