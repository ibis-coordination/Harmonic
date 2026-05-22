# typed: true

class OauthIdentity < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :user

  sig { params(auth: T.untyped).returns(OauthIdentity) }
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
    omni = user.find_or_create_omni_auth_identity!

    # Trust the OAuth provider's verified-email claim — but ONLY for real OAuth
    # providers (Google, GitHub, etc.). The OmniAuth Identity gem uses
    # provider="identity" for email/password signups, and that flow does NOT
    # verify the email — those users must complete the /confirm-email
    # round-trip. Only set on first sight so repeat sign-ins don't bump the
    # timestamp away from the original confirmation.
    if auth.provider.to_s != "identity" && omni.email_confirmed_at.nil?
      omni.update!(email_confirmed_at: Time.current)
    end

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

  sig { params(auth: T.untyped).returns(T.nilable(String)) }
  def self.url_from_auth(auth)
    case auth.provider
    when 'github'
      auth.info.urls.GitHub
    end
  end
end