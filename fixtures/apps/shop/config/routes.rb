Rails.application.routes.draw do
  # Health check: 200 if the app boots.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :orders, only: %i[index show create] do
    patch :cancel, on: :member
  end
  root "orders#index"
end
