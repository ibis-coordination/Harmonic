# typed: strict

# Sorbet shim for Current (ActiveSupport::CurrentAttributes).
# The `attribute` macro generates class-level getters and setters dynamically;
# Sorbet cannot see them, so we declare them explicitly here.
class Current < ActiveSupport::CurrentAttributes
  class << self
    sig { returns(T.nilable(String)) }
    def tenant_id; end

    sig { params(value: T.nilable(String)).void }
    def tenant_id=(value); end

    sig { returns(T.nilable(String)) }
    def tenant_subdomain; end

    sig { params(value: T.nilable(String)).void }
    def tenant_subdomain=(value); end

    sig { returns(T.nilable(String)) }
    def main_collective_id; end

    sig { params(value: T.nilable(String)).void }
    def main_collective_id=(value); end

    sig { returns(T.nilable(String)) }
    def collective_id; end

    sig { params(value: T.nilable(String)).void }
    def collective_id=(value); end

    sig { returns(T.nilable(String)) }
    def collective_handle; end

    sig { params(value: T.nilable(String)).void }
    def collective_handle=(value); end

    sig { returns(T.nilable(String)) }
    def ai_agent_task_run_id; end

    sig { params(value: T.nilable(String)).void }
    def ai_agent_task_run_id=(value); end

    sig { returns(T.nilable(String)) }
    def automation_rule_run_id; end

    sig { params(value: T.nilable(String)).void }
    def automation_rule_run_id=(value); end

    sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def automation_chain; end

    sig { params(value: T.nilable(T::Hash[Symbol, T.untyped])).void }
    def automation_chain=(value); end
  end
end
