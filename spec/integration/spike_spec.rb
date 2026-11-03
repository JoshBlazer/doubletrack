# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# M0 exit check as a test: boots the real shop fixture on Rails 8.0 and 8.1.
# Requires the fixture bundles (`make fixtures`).
RSpec.describe "bin/doubletrack-spike on fixtures/apps/shop", :integration do
  root = File.expand_path("../..", __dir__)
  shop = File.join(root, "fixtures/apps/shop")

  def spike(root, *args)
    # Run outside our own bundle, exactly like a user would.
    env = {"BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil}
    Open3.capture3(env, RbConfig.ruby, File.join(root, "bin/doubletrack-spike"), *args)
  end

  it "boots both twins on different Rails versions and gets a response from each" do
    out, err, status = spike(root, shop, "--path", "/orders", "--json")
    expect(status.exitstatus).to eq(0), "spike failed:\n#{err}"

    report = JSON.parse(out)
    hellos = report["twins"].map { |t| t["hello"] }
    expect(hellos.map { |h| h["role"] }).to eq(%w[control_a candidate_b])
    expect(hellos[0]["rails_version"]).to start_with("8.0.")
    expect(hellos[1]["rails_version"]).to start_with("8.1.")
    expect(hellos.map { |h| h["rails_env"] }).to all(eq("doubletrack"))
    expect(hellos.map { |h| File.basename(h["bundle_gemfile"]) }).to eq(%w[Gemfile Gemfile.next])

    responses = report["twins"].map { |t| t.dig("trace", "response") }
    expect(responses.map { |r| r["status"] }).to eq([200, 200])
    bodies = responses.map { |r| Doubletrack::Protocol::Message.decode_body(r["body"]) }
    expect(bodies).to all(include("<h1>Orders</h1>", "No orders yet."))
  end

  it "does not write into the app directory (hard constraint 7)" do
    expect(File).not_to exist(File.join(shop, "log/doubletrack.log"))
    expect(Dir.glob(File.join(shop, "config/environments/doubletrack*"))).to be_empty
  end

  it "exits 2 with a clear message when the app has no Gemfile.next" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), "")
      _, err, status = spike(root, dir)
      expect(status.exitstatus).to eq(2)
      expect(err).to include("Gemfile.next not found")
    end
  end
end
