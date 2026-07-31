# typed: false

# Both account-deletion emails: the confirmation at request time and the
# reminder shortly before the scrub. Sending them is possible precisely
# because the email address survives until the scrub. tenant provides the
# restore URL; subdomain_only distinguishes a per-subdomain deletion from a
# global one.
class AccountDeletionMailer < ApplicationMailer
  def deletion_requested(user:, tenant:, scrub_date:, subdomain_only: false)
    @user = user
    @subdomain = tenant.subdomain
    @subdomain_only = subdomain_only
    @scrub_date = scrub_date
    @restore_url = "#{tenant.url}/account/deletion"

    subject = if subdomain_only
                "Your account on #{@subdomain} is scheduled for deletion"
              else
                "Your account is scheduled for deletion"
              end
    mail(to: user.email, subject: subject)
  end

  def deletion_reminder(user:, tenant:, scrub_date:, subdomain_only: false)
    @user = user
    @subdomain = tenant.subdomain
    @subdomain_only = subdomain_only
    @scrub_date = scrub_date
    @restore_url = "#{tenant.url}/account/deletion"

    subject = if subdomain_only
                "Your account on #{@subdomain} will be permanently deleted on #{scrub_date.to_fs(:long)}"
              else
                "Your account will be permanently deleted on #{scrub_date.to_fs(:long)}"
              end
    mail(to: user.email, subject: subject)
  end
end
