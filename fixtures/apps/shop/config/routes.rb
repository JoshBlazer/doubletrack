Rails.application.routes.draw do
  # Health check: 200 if the app boots.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :orders, only: %i[index show create] do
    get :recent, on: :collection
    patch :cancel, on: :member
    patch :audit, on: :member
    post :receipt, on: :member
  end

  # Doubletrack M12 (ADR 0039): a raw-body webhook and a host-constrained admin route.
  post "webhooks/payments" => "webhooks#payments", as: :payments_webhook
  constraints host: "admin.example.com" do
    get "admin/stats" => "admin#stats"
  end
  root "orders#index"
end
