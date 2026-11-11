# Bot defenses (honeypot + Turnstile) for the two OmniAuth-handled POSTs:
# /auth/identity/register and /auth/identity/callback. The controller-level
# BotProtection concern can't see those requests because OmniAuth consumes
# them first — so we mount a small Rack middleware in FRONT of OmniAuth.
require Rails.root.join("app/middleware/omni_auth_bot_protection")
Rails.application.config.middleware.use OmniAuthBotProtection

Rails.application.config.middleware.use OmniAuth::Builder do
  if Rails.env.development?
    provider :developer
  end

  provider :identity,
    model: OmniAuthIdentity,
    fields: [:email, :name],
    on_login: SessionsController.action(:new),
    on_registration: OmniAuthIdentitiesController.action(:new),
    on_failed_registration: OmniAuthIdentitiesController.action(:failed_registration)

  provider :github,
    ENV['GITHUB_CLIENT_ID'],
    ENV['GITHUB_CLIENT_SECRET'],
    scope: 'user:email'
end

OmniAuth.config.allowed_request_methods = [:post]
OmniAuth.config.silence_get_warning = true
OmniAuth.config.failure_raise_out_environments = []

# OmniAuth builds the callback URL it sends to the provider from the request's
# host, which a client can forge. OAuth only runs on the auth host (HOSTNAME
# itself in single-tenant mode), so that is the one host allowed; requests on
# any other host fail with invalid_host. Without the env vars (e.g. during
# asset precompilation) no host is allowed, so OAuth fails closed.
module OmniAuthAllowedHosts
  def self.for_env(env)
    hostname = env["HOSTNAME"].to_s.split(":").first
    return [] if hostname.blank?
    return [hostname] if env["SINGLE_TENANT_MODE"] == "true"

    auth_subdomain = env["AUTH_SUBDOMAIN"]
    return [] if auth_subdomain.blank?

    ["#{auth_subdomain}.#{hostname}"]
  end
end

OmniAuth.config.allowed_hosts = OmniAuthAllowedHosts.for_env(ENV)

if Rails.env.development?
  # OmniAuth.config.test_mode = true
  OmniAuth.config.add_mock(:developer, {
    provider: 'developer',
    uid: '12345',
    info: {
      name: 'Test User',
      email: 'test@example.com',
      image: 'https://avatars.githubusercontent.com/u/12345?v=4',
      nickname: 'testuser',
      urls: { Developer: 'https://github.com/testuser' }
    },
    credentials: { token: 'testtoken', secret: 'testsecret' }
  })
end