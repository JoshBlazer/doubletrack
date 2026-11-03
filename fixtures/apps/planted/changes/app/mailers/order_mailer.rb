class OrderMailer < ApplicationMailer
  def confirmation
    @order = params[:order]
    # P3: subject of the mail sent by a job changes (data-changing; seen only with jobs performed)
    subject = Planted.on? ? "Your order ##{@order.id} is confirmed" : "Order ##{@order.id} confirmed"
    mail to: @order.user.email, subject: subject
  end

  def cancellation
    @order = params[:order]
    mail to: @order.user.email, subject: "Order ##{@order.id} cancelled"
  end
end
