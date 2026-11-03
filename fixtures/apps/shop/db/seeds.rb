ada = User.find_or_create_by!(email: "ada@example.com") { |u| u.name = "Ada" }
grace = User.find_or_create_by!(email: "grace@example.com") { |u| u.name = "Grace" }

ada.orders.find_or_create_by!(total_cents: 1999, currency: "USD")
grace.orders.find_or_create_by!(total_cents: 4250, currency: "EUR", status: "paid")
