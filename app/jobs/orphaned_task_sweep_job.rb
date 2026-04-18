# typed: true
# frozen_string_literal: true

# Sweeps for agent task runs stuck in "running" state.
#
# Belt-and-suspenders for cases where XAUTOCLAIM can't recover:
# - Stream entry was ACK'd but task row wasn't updated (crash between ACK and /complete)
# - Redis was wiped or the stream was deleted
# - The agent-runner never restarted after a crash
#
# Runs every 10 minutes via sidekiq-cron.
class OrphanedTaskSweepJob < SystemJob
  ORPHAN_THRESHOLD = 15.minutes

  def perform
    orphaned = AiAgentTaskRun.unscoped_for_system_job
      .where(status: "running")
      .where("started_at < ?", ORPHAN_THRESHOLD.ago)

    orphaned.find_each do |task_run|
      task_run.update!(
        status: "failed",
        success: false,
        error: "orphaned_timeout",
        completed_at: Time.current,
      )
      Rails.logger.warn(
        "[OrphanedTaskSweep] Marked task #{task_run.id} as failed " \
        "(started_at: #{task_run.started_at}, agent: #{task_run.ai_agent&.name})",
      )
    end
  end
end
