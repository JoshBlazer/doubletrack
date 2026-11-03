# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "socket"
require "tmpdir"
require "doubletrack"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed

  # Engineering standard: no test may touch the network. Fail loudly if one tries.
  # (Unix sockets and pipes are unaffected; twins talk over pipes.)
  config.before do
    allow(TCPSocket).to receive(:new).and_raise("network access is forbidden in tests")
    allow(Socket).to receive(:tcp).and_raise("network access is forbidden in tests")
  end
end
