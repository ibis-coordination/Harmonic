# typed: false
# frozen_string_literal: true

# Yabeda application metrics configuration
# https://github.com/yabeda-rb/yabeda

# Skip metrics initialization in test environment
return if Rails.env.test?

Yabeda.configure do
  # Authentication metrics
  group :auth do
    counter :login_attempts_total,
            comment: "Total login attempts",
            tags: [:result, :tenant_id]

    counter :password_resets_total,
            comment: "Total password reset requests",
            tags: [:tenant_id]
  end

  # Content creation metrics
  group :content do
    counter :notes_created_total,
            comment: "Total notes created",
            tags: [:tenant_id, :superagent_id]

    counter :decisions_created_total,
            comment: "Total decisions created",
            tags: [:tenant_id, :superagent_id]

    counter :commitments_created_total,
            comment: "Total commitments created",
            tags: [:tenant_id, :superagent_id]

    counter :votes_cast_total,
            comment: "Total votes cast on decisions",
            tags: [:tenant_id, :superagent_id, :vote_type]
  end

  # API metrics
  group :api do
    counter :requests_total,
            comment: "Total API requests",
            tags: [:tenant_id, :endpoint, :method, :status]

    histogram :request_duration_seconds,
              comment: "API request duration in seconds",
              tags: [:tenant_id, :endpoint, :method],
              buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
  end

  # Security metrics
  group :security do
    counter :rate_limited_total,
            comment: "Total rate limited requests",
            tags: [:endpoint]

    counter :ip_blocked_total,
            comment: "Total IP blocks",
            tags: [:reason]
  end

  # Active users gauge (updated periodically)
  group :users do
    gauge :active_users,
          comment: "Number of users active in the last 15 minutes",
          tags: [:tenant_id]
  end
end

# NOTE: yabeda-rails and yabeda-sidekiq auto-install via Railtie
# No manual installation needed
