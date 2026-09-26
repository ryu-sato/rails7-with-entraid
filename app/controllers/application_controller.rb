class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Every action requires sign-in by default (5.1). Public pages opt out
  # explicitly with skip_before_action :authenticate_user! (5.3, 5.4).
  before_action :authenticate_user!
end
