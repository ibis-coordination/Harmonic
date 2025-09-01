class ApplicationMailer < ActionMailer::Base
  default from: ENV['MAILER_FROM_ADDRESS'] || "noreply@#{ENV['HOSTNAME'] || 'harmonicteam.com'}"
  layout "mailer"
end
