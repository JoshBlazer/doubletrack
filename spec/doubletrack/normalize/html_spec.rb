# frozen_string_literal: true

require "doubletrack/normalize/html"

RSpec.describe Doubletrack::Normalize::Html do
  def tree(html) = described_class.call(html)

  let(:page) do
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta name="csrf-token" content="abc123">
          <meta name="csrf-param" content="authenticity_token">
          <script nonce="n0nce">1</script>
        </head>
        <body>
          <!-- a comment -->
          <h1 class="title" id="t">Orders</h1>
          <form><input type="hidden" name="authenticity_token" value="tok"><input name="q" value="x"></form>
          <p>Hello,
             world</p>
        </body>
      </html>
    HTML
  end

  it "builds a tag/attrs/children tree with collapsed text" do
    body = tree(page)["children"].find { |n| n.is_a?(Hash) && n["tag"] == "body" }
    h1 = body["children"].find { |n| n.is_a?(Hash) && n["tag"] == "h1" }
    expect(h1).to eq("tag" => "h1", "attrs" => {"class" => "title", "id" => "t"}, "children" => ["Orders"])
    p_tag = body["children"].find { |n| n.is_a?(Hash) && n["tag"] == "p" }
    expect(p_tag["children"]).to eq(["Hello, world"])
  end

  it "strips volatile tokens: CSRF meta, authenticity_token inputs, nonces" do
    flat = tree(page).to_s
    expect(flat).not_to include("abc123", "tok", "n0nce")
    expect(flat).to include("authenticity_token") # the param name is kept, only values go
  end

  it "is invariant under attribute order, inter-tag whitespace, comments and token values" do
    variant = page.sub('class="title" id="t"', 'id="t"   class="title"')
      .gsub("\n        ", "\n").sub("<!-- a comment -->", "")
      .sub("abc123", "zzz999").sub('value="tok"', 'value="other"').sub("n0nce", "other")
    expect(tree(variant)).to eq(tree(page))
  end

  it "is idempotent through canonical serialization" do
    once = described_class.canonical(page)
    expect(described_class.canonical(once)).to eq(once)
    expect(tree(once)).to eq(tree(page))
  end

  it "still sees changed text, attributes and structure" do
    expect(tree(page.sub("Orders", "Orders!"))).not_to eq(tree(page))
    expect(tree(page.sub('id="t"', 'id="u"'))).not_to eq(tree(page))
    expect(tree(page.sub("<h1", "<h2").sub("</h1>", "</h2>"))).not_to eq(tree(page))
  end

  it "handles fragments (mail bodies)" do
    expect(described_class.canonical("<p>Hi  <b>Ada</b></p>\n")).to eq(described_class.canonical("<p>Hi <b>Ada</b></p>"))
  end

  it "keeps whitespace inside pre" do
    expect(tree("<pre>a\n  b</pre>")).not_to eq(tree("<pre>a b</pre>"))
  end
end
