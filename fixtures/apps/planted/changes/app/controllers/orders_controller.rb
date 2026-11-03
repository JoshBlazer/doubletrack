require "securerandom"

# Same controller as fixtures/apps/shop, with planted behavior changes (Planted.on?) and
# planted noise. Each plant is tagged with its id from doubletrack/expected.yml.
class OrdersController < ApplicationController
  def index
    @orders = Order.includes(:user).order(:id)
    @summary = Rails.cache.fetch("orders/summary") do
      summary = { "count" => Order.count, "total_cents" => Order.sum(:total_cents) }
      summary["currency"] = "USD" if Planted.on? # P5: cached value gains a key (data-changing)
      summary
    end

    respond_to do |format|
      format.html
      format.json { render json: { summary: @summary, orders: @orders.map { |o| order_json(o) } } }
    end
  end

  def show
    @order = Order.find(params[:id])
    @currency = params.fetch(:currency, @order.currency)
    @converted_cents = (@order.total_cents * ExchangeRates.rate(@currency)).round
    expires_in 5.minutes if Planted.on? # P9: cache-control header changes (cosmetic)

    respond_to do |format|
      format.html
      format.json do
        json = order_json(@order).merge("converted" => { "currency" => @currency, "cents" => @converted_cents })
        json["total"] = @order.total if Planted.on? # P7: new key in the JSON body (user-visible)
        json["request_token"] = SecureRandom.hex(4) # N1: noise on every version; must be masked
        render json: json
      end
    end
  end

  def create
    user = User.find_or_create_by!(email: params.require(:email)) do |u|
      name = params.fetch(:name, "Guest")
      u.name = Planted.on? ? name.squish : name.strip # P1: different value written (data-changing)
    end
    order = user.orders.new(order_params)

    if order.save
      Rails.cache.delete("orders/summary")
      remember_recent(order)
      render json: order_json(order), status: :created, location: order
    else
      status = Planted.on? ? :bad_request : :unprocessable_entity # P6: status code (user-visible)
      render json: { errors: order.errors.full_messages }, status: status
    end
  end

  # P8: the redirect target changes (user-visible).
  def latest
    order = Order.order(:id).last
    return head :not_found unless order

    redirect_to Planted.on? ? order_path(order, format: :json) : order_path(order)
  end

  def recent
    ids = Array(session[:recent_order_ids])
    orders = Order.includes(:user).where(id: ids).sort_by { |o| ids.index(o.id) }
    render json: { recent: orders.map { |o| order_json(o) } }
  end

  def cancel
    order = Order.find(params[:id])
    order.update!(status: "cancelled")
    OrderMailer.with(order: order).cancellation.deliver_now
    Rails.cache.delete("orders/summary")

    render json: order_json(order)
  end

  private

  def remember_recent(order)
    session[:recent_order_ids] = (Array(session[:recent_order_ids]) + [order.id]).last(5)
  end

  def order_params
    params.permit(:total_cents, :currency)
  end

  def order_json(order)
    order.as_json(only: %i[id total_cents currency status created_at]).merge("user_email" => order.user.email)
  end
end
