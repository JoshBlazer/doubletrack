require "test_helper"

class OrderMailerTest < ActionMailer::TestCase
  test "confirmation" do
    user = User.create!(name: "Ada", email: "ada@example.com")
    order = user.orders.create!(total_cents: 1999)

    mail = OrderMailer.with(order: order).confirmation
    assert_equal "Order ##{order.id} confirmed", mail.subject
    assert_equal [ "ada@example.com" ], mail.to
    assert_match "19.99 USD", mail.body.encoded
  end
end
