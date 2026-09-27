Rails.application.routes.draw do
  # Only the OmniAuth routes: /users/auth/openid_connect (POST) and
  # /users/auth/openid_connect/callback. No sessions / registrations routes.
  devise_for :users, only: [ :omniauth_callbacks ],
             controllers: { omniauth_callbacks: "users/omniauth_callbacks" }

  # Own login / logout routes. The names let Devise's FailureApp redirect
  # unauthenticated requests to /login. Logout is DELETE only.
  devise_scope :user do
    get "login", to: "sessions#new", as: :new_user_session
    delete "logout", to: "sessions#destroy", as: :destroy_user_session
    get "signed_out", to: "sessions#signed_out"
  end

  root "home#index"

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
