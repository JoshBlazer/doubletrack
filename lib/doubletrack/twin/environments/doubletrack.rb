# frozen_string_literal: true

# The `doubletrack` Rails environment (ADR 0009). Loaded by Rails's
# load_environment_config initializer because the twin appends this directory to
# Rails.application.paths["config/environments"]. Nothing is written into the app.
#
# Start from the app's own test environment, then force sandbox settings.
app_test_env = Rails.root.join("config", "environments", "test.rb")
load app_test_env.to_s if app_test_env.exist?

Rails.application.configure do
  config.eager_load = false

  # Logs go to the twin's stdout, which the twin redirected to its own log file,
  # so nothing is written into the app's log/ directory.
  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :info

  # Hard constraint 8: nothing escapes the sandbox.
  if defined?(ActionMailer::Railtie)
    config.action_mailer.delivery_method = :test
    config.action_mailer.perform_deliveries = true
  end
  config.active_job.queue_adapter = :test if defined?(ActiveJob::Railtie)

  # ADR 0011: an observable cache, cleared by the twin at the start of each session.
  config.cache_store = :memory_store

  # Rescuable exceptions (e.g. RecordNotFound) become their production status codes;
  # anything else propagates and is recorded in the trace as an exception.
  config.action_dispatch.show_exceptions = :rescuable

  # Requests come from ActionDispatch::Integration::Session (host www.example.com).
  config.hosts.clear if config.respond_to?(:hosts)
end
