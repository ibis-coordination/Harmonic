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