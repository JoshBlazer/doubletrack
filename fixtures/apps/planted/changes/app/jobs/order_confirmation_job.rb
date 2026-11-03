class OrderConfirmationJob < ApplicationJob
  queue_as { Planted.on? ? :mailers : :default } # P2: queue changes (data-changing)

  def perform(order)
    OrderMailer.with(order: order).confirmation.deliver_now
  end
end
