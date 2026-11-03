# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~integration"
end

namespace :spec do
  desc "Integration specs: boot real fixture apps on two Rails versions (needs fixture bundles installed)"
  RSpec::Core::RakeTask.new(:integration) do |t|
    t.rspec_opts = "--tag integration"
  end
end

task default: %i[standard spec]
