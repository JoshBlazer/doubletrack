# Preview all emails at http://localhost:3000/rails/mailers/order_mailer
class OrderMailerPreview < ActionMailer::Preview
  def confirmation
    OrderMailer.with(order: Order.first || Order.new(id: 1, total_cents: 1999, user: User.new(name: "Ada", email: "ada@example.com"))).confirmation
  end
end
