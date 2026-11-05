# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "standard", "~> 1.50"
  # parallel >= 2.0 (via rubocop) requires Ruby 3.3; keep the dev bundle installable on 3.2.
  gem "parallel", "< 2", require: false
  # Unit specs of the SQLite snapshot restore (twins use the app's own sqlite3).
  gem "sqlite3", ">= 2.1", require: false
end
