# Served only on admin.example.com (Doubletrack M12: the request host is captured and
# replayed, so host-constrained routes match).
class AdminController < ApplicationController
  def stats
    render json: { orders: Order.count, host: request.host }
  end
end
