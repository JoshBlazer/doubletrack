require "test_helper"

# Request-level tests. Doubletrack's M5 derives replay sessions from tests like these.
class OrdersFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ExchangeRates.client = ->(_uri) { { "rates" => { "EUR" => 0.9, "GBP" => 0.8 } }.to_json }
  end

  teardown { ExchangeRates.client = nil }

  test "creating an order enqueues the confirmation job, and the job sends mail" do
    assert_enqueued_with(job: OrderConfirmationJob) do
      post orders_path, params: { email: "ada@example.com", name: "Ada", total_cents: 1999 }, as: :json
    end
    assert_response :created
    assert_equal "ada@example.com", response.parsed_body["user_email"]

    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.last
    assert_equal ["ada@example.com"], mail.to
    assert_match "confirmed", mail.subject
  end

  test "invalid orders are rejected" do
    post orders_path, params: { email: "ada@example.com", total_cents: 0 }, as: :json
    assert_response :unprocessable_entity
  end

  test "index lists orders as HTML and JSON" do
    post orders_path, params: { email: "grace@example.com", total_cents: 4250, currency: "EUR" }, as: :json

    get orders_path
    assert_response :success
    assert_select "td", text: "grace@example.com"

    get orders_path(format: :json)
    assert_equal 1, response.parsed_body.dig("summary", "count")
  end

  test "show converts currency through the rates API" do
    post orders_path, params: { email: "ada@example.com", total_cents: 1000 }, as: :json
    id = response.parsed_body["id"]

    get order_path(id, currency: "EUR", format: :json)
    assert_equal 900, response.parsed_body.dig("converted", "cents")
  end
end
