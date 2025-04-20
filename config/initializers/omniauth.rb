Rails.application.config.middleware.use OmniAuth::Builder do
  if Rails.env.development?
    provider :developer
  end

  provider :github,
    ENV['GITHUB_CLIENT_ID'],
    ENV['GITHUB_CLIENT_SECRET'],
    scope: 'user:email'
end

if Rails.env.development?
  OmniAuth.config.test_mode = true
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