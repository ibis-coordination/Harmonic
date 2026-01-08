# typed: false

class OauthIdentity < ApplicationRecord
  self.implicit_order_column = "created_at"
  belongs_to :user

  def self.find_or_create_from_auth(auth)
    identity = find_or_initialize_by(
      provider: auth.provider,
      uid: auth.uid
    )

    # If identity isn't linked to a user, check for an existing user with the same email
    if identity.user_id.nil? && auth.info.email
      user = User.find_by(email: auth.info.email)
    end

    # Create new user if needed
    user ||= identity.user || User.create!(
      email: auth.info.email,
      name: auth.info.name,
      image_url: auth.info.image,
    )

    # We want to make sure that every user has an oaid record even if
    # they use an oauth provider like github. This ensures that the email address
    # cannot be claimed by a different user signing up for the first time.
    user.find_or_create_omni_auth_identity!

    # Link identity to user
    identity.update!(
      user: user,
      last_sign_in_at: Time.current,
      url: url_from_auth(auth),
      username: auth.info.nickname,
      image_url: auth.info.image,
      auth_data: auth
    )

    identity
  end

  private

  def self.url_from_auth(auth)
    case auth.provider
    when 'github'
      auth.info.urls.GitHub
    end
  end
end