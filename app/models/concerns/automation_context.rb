# typed: true

# Thread-local storage for automation context.
# Used to pass the current automation run ID through to models being created.
#
# Example usage:
#   AutomationContext.with_run(run) do
#     Note.create!(text: "Hello")  # Will automatically set automation_rule_run_id
#   end
module AutomationContext
  extend T::Sig

  sig { returns(T.nilable(String)) }
  def self.current_run_id
    Thread.current[:automation_rule_run_id]
  end

  sig { params(id: T.nilable(String)).void }
  def self.current_run_id=(id)
    Thread.current[:automation_rule_run_id] = id
  end

  sig { returns(T.nilable(AutomationRuleRun)) }
  def self.current_run
    return nil unless current_run_id

    AutomationRuleRun.find_by(id: current_run_id)
  end

  # Execute a block with the given automation run as context.
  # Resources created within the block will have automation_rule_run_id set.
  sig do
    type_parameters(:T)
      .params(run: AutomationRuleRun, blk: T.proc.returns(T.type_parameter(:T)))
      .returns(T.type_parameter(:T))
  end
  def self.with_run(run, &blk)
    old_id = current_run_id
    self.current_run_id = run.id
    yield
  ensure
    self.current_run_id = old_id
  end

  sig { void }
  def self.clear!
    self.current_run_id = nil
  end
end
