class OrderMailer < ApplicationMailer
  def confirmation
    @order = params[:order]
    mail to: @order.user.email, subject: "Order ##{@order.id} confirmed"
  end
end
