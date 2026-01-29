# typed: false

namespace :maintenance do
  desc "Clean up expired and soft-deleted API tokens older than 30 days"
  task cleanup_tokens: :environment do
    CleanupExpiredTokensJob.perform_now
  end
end
