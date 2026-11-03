class OrdersController < ApplicationController
  def index
    @orders = Order.includes(:user).order(:id)
    @summary = Rails.cache.fetch("orders/summary") do
      { "count" => Order.count, "total_cents" => Order.sum(:total_cents) }
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

    respond_to do |format|
      format.html
      format.json { render json: order_json(@order).merge(converted: { currency: @currency, cents: @converted_cents }) }
    end
  end

  def create
    user = User.find_or_create_by!(email: params.require(:email)) { |u| u.name = params.fetch(:name, "Guest") }
    order = user.orders.new(order_params)

    if order.save
      Rails.cache.delete("orders/summary")
      remember_recent(order)
      render json: order_json(order), status: :created, location: order
    else
      render json: { errors: order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # Orders created in this browser session, newest last (kept in the session cookie).
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
