class ApplicationMailer < ActionMailer::Base
  default from: ENV['MAILER_FROM_ADDRESS']
  layout "mailer"
end
