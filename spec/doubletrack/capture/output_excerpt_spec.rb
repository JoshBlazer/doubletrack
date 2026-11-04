# frozen_string_literal: true

require "doubletrack/capture"

# When the app's tests crash before running (a boot error), the exception message comes
# before a long backtrace. Showing only the last lines hid it (seen on once-campfire).
RSpec.describe "Doubletrack::Capture.output_excerpt" do
  def excerpt(text) = Doubletrack::Capture.output_excerpt(text, tail: 5)

  it "is the last lines when there is no backtrace" do
    text = (1..8).map { |i| "line #{i}\n" }.join
    expect(excerpt(text)).to eq((4..8).map { |i| "line #{i}\n" }.join)
  end

  it "keeps the exception message line above a backtrace that the tail cuts off" do
    text = "Run options: --seed 1\n" \
      "/app/config/initializers/x.rb:3:in '<main>': uninitialized constant Foo (NameError)\n" +
      (1..40).map { |i| "\tfrom /gems/f#{i}.rb:#{i}:in 'm'\n" }.join
    out = excerpt(text)
    expect(out).to start_with("/app/config/initializers/x.rb:3:in '<main>': uninitialized constant Foo (NameError)\n")
    expect(out).to include("\t... 35 lines omitted ...\n")
    expect(out).to end_with("\tfrom /gems/f40.rb:40:in 'm'\n")
    expect(out).not_to include("Run options")
  end

  it "doesn't repeat the message when the tail already shows it" do
    text = "boom (RuntimeError)\n\tfrom a.rb:1\n\tfrom b.rb:2\n"
    expect(excerpt(text)).to eq(text)
  end
end
