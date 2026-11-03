require "net/http"
require "json"

# The shop's one outbound HTTP dependency: a currency-rate API, called via Net::HTTP.
# Doubletrack intercepts this during replay (M2); the shop's own tests swap the client.
module ExchangeRates
  ENDPOINT = URI("https://rates.example.test/latest")

  class << self
    # A callable taking a URI and returning a JSON string. Replaceable in tests.
    attr_writer :client

    def client
      @client ||= ->(uri) { Net::HTTP.get(uri) }
    end

    # @return [Float] units of `currency` per 1 USD
    def rate(currency)
      return 1.0 if currency == "USD"

      uri = ENDPOINT.dup
      uri.query = URI.encode_www_form(base: "USD", symbols: currency)
      JSON.parse(client.call(uri)).fetch("rates").fetch(currency).to_f
    end
  end
end
