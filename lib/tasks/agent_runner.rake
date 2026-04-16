# typed: false

namespace :agent_runner do
  desc "Re-dispatch queued AiAgentTaskRuns to the agent-runner Redis stream. " \
       "Run this once during Phase 2 cutover to pick up tasks that were " \
       "queued under the old Sidekiq path but never published to the stream."
  task redispatch_queued: :environment do
    queued = AiAgentTaskRun.unscoped_for_system_job.where(status: "queued")
    total = queued.count
    puts "Found #{total} queued task run(s) to re-dispatch."

    dispatched = 0
    failed = 0
    queued.find_each do |task_run|
      Tenant.scope_thread_to_tenant(subdomain: task_run.tenant.subdomain)
      AgentRunnerDispatchService.dispatch(task_run)
      dispatched += 1
      print "." if (dispatched % 10).zero?
    rescue => e
      failed += 1
      warn "\n  failed #{task_run.id}: #{e.class} #{e.message}"
    ensure
      Tenant.clear_thread_scope
    end

    puts ""
    puts "Dispatched: #{dispatched}"
    puts "Failed:     #{failed}" if failed.positive?
  end
end
