# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn
]

# OAuth / OpenID Connect values. code and state are matched exactly (anchored)
# so that unrelated parameters such as zipcode or estate are not masked.
# id_token / access_token / client_secret are already covered by :token and
# :secret above.
Rails.application.config.filter_parameters += [
  /\Acode\z/, /\Astate\z/, /\Anonce\z/, :login_hint
]
