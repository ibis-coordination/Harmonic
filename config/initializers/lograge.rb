# typed: false
# frozen_string_literal: true

# Lograge configuration for structured logging
# https://github.com/roidrage/lograge

Rails.application.configure do
  # Enable lograge in production (can be enabled in other envs via ENV var)
  config.lograge.enabled = Rails.env.production? || ENV["LOGRAGE_ENABLED"] == "true"

  # Use JSON format for easier parsing by log aggregators
  config.lograge.formatter = Lograge::Formatters::Json.new

  # Keep original Rails logs alongside lograge (set to false in production for less noise)
  config.lograge.keep_original_rails_log = !Rails.env.production?

  # Include request parameters (excluding sensitive ones)
  config.lograge.custom_options = lambda do |event|
    exceptions = ["controller", "action", "format", "id"]

    {
      # Request metadata
      request_id: event.payload[:request_id],
      host: event.payload[:host],
      remote_ip: event.payload[:remote_ip],

      # Multi-tenancy context
      tenant_id: event.payload[:tenant_id],
      collective_id: event.payload[:collective_id],
      user_id: event.payload[:user_id],

      # Request details
      params: event.payload[:params]&.except(*exceptions),
      time: Time.current.iso8601(3),

      # Exception info if present
      exception: event.payload[:exception]&.first,
      exception_message: event.payload[:exception]&.last,
    }.compact
  end

  # Add custom data to the payload via ApplicationController
  config.lograge.custom_payload do |controller|
    {
      host: controller.request.host,
      remote_ip: controller.request.remote_ip,
      request_id: controller.request.request_id,
      tenant_id: controller.instance_variable_get(:@current_tenant)&.id,
      collective_id: controller.instance_variable_get(:@current_collective)&.id,
      user_id: controller.instance_variable_get(:@current_user)&.id,
    }
  end

  # Ignore certain paths from logging
  config.lograge.ignore_actions = [
    "HealthcheckController#show",
  ]
end
