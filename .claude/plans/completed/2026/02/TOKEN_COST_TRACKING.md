# Token and Cost Tracking for AI Agent Task Runs

**Status: COMPLETED** (2026-02-11)

## Summary

Track LLM token usage and estimated costs for AI agent task runs. Token counts are captured from LLM API responses and persisted with computed costs.

**Scope:**
- Track totals per task run (input/output/total tokens, estimated cost)
- Display usage in UI on task run detail, runs list, and agent index pages
- No budgets or limits (future work)

## Implementation

### Phase 1: Migration ✅

Created `db/migrate/20260211114428_add_token_usage_to_ai_agent_task_runs.rb`:

```ruby
class AddTokenUsageToAiAgentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :ai_agent_task_runs, :input_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :output_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :total_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :estimated_cost_usd, :decimal, precision: 10, scale: 6

    add_index :ai_agent_task_runs, [:tenant_id, :created_at]
    add_index :ai_agent_task_runs, [:ai_agent_id, :created_at]
  end
end
```

### Phase 2: LLMPricing Service ✅

Created `app/services/llm_pricing.rb` with Sorbet types:

```ruby
class LLMPricing
  # Prices per 1M tokens (USD)
  PRICING = {
    # Claude 4 models
    "claude-sonnet-4-20250514" => { input: 3.00, output: 15.00 },
    "claude-haiku-4-20250514" => { input: 0.80, output: 4.00 },
    # Claude 3.5 models
    "claude-3-5-sonnet-20241022" => { input: 3.00, output: 15.00 },
    "claude-3-5-haiku-20241022" => { input: 0.80, output: 4.00 },
    # Claude 3 models
    "claude-3-opus-20240229" => { input: 15.00, output: 75.00 },
    "claude-3-sonnet-20240229" => { input: 3.00, output: 15.00 },
    "claude-3-haiku-20240307" => { input: 0.25, output: 1.25 },
    # OpenAI models
    "gpt-4o" => { input: 2.50, output: 10.00 },
    "gpt-4o-mini" => { input: 0.15, output: 0.60 },
    # Default fallback
    "default" => { input: 3.00, output: 15.00 },
  }.freeze

  def self.calculate_cost(model:, input_tokens:, output_tokens:)
    pricing = PRICING[model] || PRICING["default"]
    (input_tokens / 1_000_000.0) * pricing[:input] + (output_tokens / 1_000_000.0) * pricing[:output]
  end

  def self.known_model?(model)
    PRICING.key?(model) && model != "default"
  end

  def self.known_models
    PRICING.keys.reject { |k| k == "default" }
  end
end
```

### Phase 3: AgentNavigator Updates ✅

Modified `app/services/agent_navigator.rb`:

1. Added instance variables in `initialize`:
   ```ruby
   @total_input_tokens = T.let(0, Integer)
   @total_output_tokens = T.let(0, Integer)
   ```

2. Accumulate usage in `think()` method after `@llm.chat`:
   ```ruby
   if result.usage.present?
     @total_input_tokens += result.usage["prompt_tokens"].to_i
     @total_output_tokens += result.usage["completion_tokens"].to_i
   end
   ```

3. Same accumulation in `prompt_for_scratchpad_update()`

4. Updated `Result` struct to include tokens:
   ```ruby
   class Result < T::Struct
     const :success, T::Boolean
     const :steps, T::Array[Step]
     const :final_message, String
     const :error, T.nilable(String)
     const :input_tokens, Integer, default: 0
     const :output_tokens, Integer, default: 0
   end
   ```

5. All return paths include `input_tokens:` and `output_tokens:`

### Phase 4: AgentQueueProcessorJob Updates ✅

Modified `app/jobs/agent_queue_processor_job.rb` `run_task` method to persist tokens and calculate cost.

### Phase 5: Model Helpers ✅

Added to `app/models/ai_agent_task_run.rb`:

```ruby
# Scopes
scope :with_usage, -> { where.not(total_tokens: 0) }
scope :in_period, ->(start_date, end_date) { where(completed_at: start_date..end_date) }

# Aggregation
def self.total_cost_for_period(start_date, end_date)
  completed.in_period(start_date, end_date).sum(:estimated_cost_usd)
end

# Formatting
def formatted_cost
  return nil unless estimated_cost_usd&.positive?
  estimated_cost_usd < 0.01 ? "< $0.01" : "$#{'%.4f' % estimated_cost_usd}"
end

def formatted_tokens
  return nil unless total_tokens&.positive?
  total_tokens.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end
```

### Phase 6: UI Display ✅

Added cost/token display to three locations:

1. **Task run detail** (`app/views/ai_agents/show_run.html.erb`):
   ```erb
   <% if @task_run.total_tokens&.positive? %>
     | Tokens: <%= @task_run.formatted_tokens %>
     <% if @task_run.formatted_cost %>
       | Est. Cost: <%= @task_run.formatted_cost %>
     <% end %>
   <% end %>
   ```

2. **Runs list** (`app/views/ai_agents/runs.html.erb`):
   - Per-run cost in metadata
   - Total cost summary at top

3. **Agent index** (`app/views/ai_agents/index.html.erb`):
   - Total estimated cost per agent (all time)

### Phase 7: Tests ✅

- `test/services/llm_pricing_test.rb` - Cost calculation, known_model?, known_models
- `test/models/ai_agent_task_run_test.rb` - Formatting helpers, scopes, aggregation

## Key Files

| File | Changes |
|------|---------|
| `db/migrate/20260211114428_add_token_usage_to_ai_agent_task_runs.rb` | New migration |
| `app/services/llm_pricing.rb` | New service |
| `app/services/agent_navigator.rb` | Accumulate tokens, update Result struct |
| `app/jobs/agent_queue_processor_job.rb` | Persist tokens and cost |
| `app/models/ai_agent_task_run.rb` | Helpers and scopes |
| `app/views/ai_agents/show_run.html.erb` | Display tokens/cost |
| `app/views/ai_agents/runs.html.erb` | Per-run and total cost display |
| `app/views/ai_agents/index.html.erb` | Per-agent total cost |
| `app/controllers/ai_agents_controller.rb` | Cost aggregation queries |

## Future Work

- **Budgets**: Per-agent token limits with period reset (daily/weekly/monthly)
- **Alerts**: Notifications when spending exceeds thresholds
- **Analytics dashboard**: Historical cost trends, per-model breakdowns
