# typed: false

class VoteReceiptMailer < ApplicationMailer
  def receipt_email(user:, decision:, receipt:)
    @user = user
    @decision = decision
    @receipt = receipt
    @verify_url = "#{decision.shareable_link}/verify/#{receipt}"

    mail(
      to: user.email,
      subject: "Vote recorded: #{decision.question}",
    )
  end
end
