require "test_helper"

# Requests that Doubletrack's capture used to skip (M12, ADR 0039): a raw request body, a
# file upload, and a host-constrained route.
class CaptureCasesTest < ActionDispatch::IntegrationTest
  test "the payments webhook reads a raw JSON body" do
    post payments_webhook_path, params: +'{"event":"payment.succeeded"}', headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success
    assert_equal "payment.succeeded", response.parsed_body["received"]
  end

  test "a receipt can be uploaded for an order" do
    post receipt_order_path(orders(:paid)), params: { receipt: fixture_file_upload("receipt.txt", "text/plain") }
    assert_response :success
    assert_equal "receipt.txt", response.parsed_body["filename"]
    assert_equal File.size(file_fixture("receipt.txt")), response.parsed_body["bytes"]
  end

  test "admin stats are served on the admin host only" do
    host! "admin.example.com"
    get "/admin/stats"
    assert_response :success
    assert_equal "admin.example.com", response.parsed_body["host"]
  end

  test "a full URL picks the host too" do
    get "http://admin.example.com/admin/stats"
    assert_response :success
  end
end
