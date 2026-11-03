class OrderMailer < ApplicationMailer
  def confirmation
    @order = params[:order]
    mail to: @order.user.email, subject: "Order ##{@order.id} confirmed"
  end

  def cancellation
    @order = params[:order]
    mail to: @order.user.email, subject: "Order ##{@order.id} cancelled"
  end
end
