# Test-only controller and routes for exercising authorization (never part of the
# app's routes; drawn per test and removed by reload_routes! in teardown).
#
#   include AuthorizationProbe   # in an ActionDispatch::IntegrationTest
#   setup { draw_authorization_probe_routes }
#
# Routes:
#   GET   /probe/read    authorize! :read   (sign-in required)
#   PATCH /probe/update  authorize! :update, then records a side effect
#   GET   /probe/open    like read, but reachable while signed out
#   GET   /probe/boom    raises an unrelated error
#   GET   /probe/links   renders can? results (view-level checks)
class AuthorizationProbeController < ApplicationController
  skip_before_action :authenticate_user!, only: :open

  class << self
    def performed
      @performed ||= []
    end
  end

  def read
    authorize! :read, :probe
    render plain: "read-ok"
  end

  def update
    authorize! :update, :probe
    self.class.performed << :update
    render plain: "update-ok"
  end

  def open
    authorize! :read, :probe
    render plain: "open-ok"
  end

  def boom
    raise "unrelated failure"
  end

  def links
    render inline: "<%= can?(:update, :probe) ? 'CAN-UPDATE' : 'NO-UPDATE' %>|<%= can?(:read, :probe) ? 'CAN-READ' : 'NO-READ' %>"
  end
end

module AuthorizationProbe
  def self.included(base)
    base.setup { AuthorizationProbeController.performed.clear }
    base.teardown { Rails.application.reload_routes! if @authorization_probe_routes_drawn }
  end

  def draw_authorization_probe_routes
    @authorization_probe_routes_drawn = true
    routes = Rails.application.routes
    routes.disable_clear_and_finalize = true
    routes.draw do
      get "probe/read", to: "authorization_probe#read"
      patch "probe/update", to: "authorization_probe#update"
      get "probe/open", to: "authorization_probe#open"
      get "probe/boom", to: "authorization_probe#boom"
      get "probe/links", to: "authorization_probe#links"
    end
  ensure
    routes.disable_clear_and_finalize = false
  end

  def create_user_with_roles(*roles)
    User.create!(tid: "tenant-1", oid: SecureRandom.uuid, roles: roles)
  end
end
