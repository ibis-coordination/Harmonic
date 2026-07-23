# typed: true

class OauthIdentity < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :user

  sig { params(auth: T.untyped, tenant: T.nilable(Tenant)).returns(OauthIdentity) }
  def self.find_or_create_from_auth(auth, tenant: nil)
    identity = find_or_initialize_by(
      provider: auth.provider,
      uid: auth.uid
    )

    # If identity isn't linked to a user, check for an existing HUMAN with the
    # same email. Scoped to humans so an OAuth login can never attach to (or
    # take over) a non-human account — agents and collective identities never
    # log in. Email is globally unique, so a non-human squatting the address
    # surfaces as a create failure below rather than a silent mis-link.
    if identity.user_id.nil? && auth.info.email
      user = User.find_by(email: auth.info.email, user_type: "human")
    end

    # Local + explicit signup flag: more durable than later asking the user
    # `previously_new_record?` from another method.
    user_was_just_created = false
    user ||= identity.user || begin
      user_was_just_created = true
      User.create!(email: auth.info.email, name: auth.info.name, image_url: auth.info.image)
    end

    # Every user needs an OmniAuthIdentity row so the email can't be claimed
    # by a separate signup later, even for OAuth-only users.
    omni = user.find_or_create_omni_auth_identity!

    # Trust real OAuth providers' verified-email claim. Email/password
    # ("identity" provider) is NOT verified here — those users complete the
    # /confirm-email round-trip. Only set on first sight so repeat sign-ins
    # don't bump the timestamp away from the original confirmation.
    if auth.provider.to_s != "identity" && omni.email_confirmed_at.nil?
      omni.update!(email_confirmed_at: Time.current)
    end

    identity.update!(
      user: user,
      last_sign_in_at: Time.current,
      url: url_from_auth(auth),
      username: auth.info.nickname,
      image_url: auth.info.image,
      auth_data: auth
    )

    if user_was_just_created && auth.provider.to_s == "identity" && tenant
      send_signup_confirmation_email(omni, tenant)
    end

    identity
  end

  sig { params(auth: T.untyped).returns(T.nilable(String)) }
  def self.url_from_auth(auth)
    case auth.provider
    when 'github'
      auth.info.urls.GitHub
    end
  end

  # Identity-provider signup is the only place we ever auto-send a
  # confirmation email — colocated with the User.create! branch in
  # find_or_create_from_auth so it's structurally impossible to fire on a
  # re-login. Subsequent confirmation emails come from the resend button on
  # /activate. Tenant is required for the correct subdomain in the link.
  sig { params(omni: OmniAuthIdentity, tenant: Tenant).void }
  def self.send_signup_confirmation_email(omni, tenant)
    raw_token = omni.send_email_confirmation!
    EmailConfirmationMailer.confirm(omni, raw_token, tenant).deliver_later
  end
  private_class_method :send_signup_confirmation_email
end