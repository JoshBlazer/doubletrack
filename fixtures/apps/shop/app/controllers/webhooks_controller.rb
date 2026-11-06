# A payments webhook that reads the raw request body, as provider webhooks do
# (Doubletrack M12: raw bodies are captured and replayed).
class WebhooksController < ApplicationController
  def payments
    payload = request.raw_post
    event = JSON.parse(payload)["event"] rescue nil
    render json: { received: event, bytes: payload.bytesize }
  end
end
