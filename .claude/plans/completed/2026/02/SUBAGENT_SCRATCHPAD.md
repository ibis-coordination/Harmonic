# Subagent Scratchpad Feature

A simple persistent text storage for subagents to maintain notes between task runs.

## Requirements

1. Every subagent has their own scratchpad
2. Displayed on `/whoami` at start of every task run
3. At end of every task run, agent is prompted to update their scratchpad

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Storage | `agent_configuration["scratchpad"]` | Reuses existing JSONB column, no migration needed |
| Action location | `/whoami/actions/update_scratchpad` | Agent starts every task at /whoami, zero navigation required |
| End-of-run prompt | **Explicit final LLM call** | Always prompt agent to update scratchpad after task ends |
| Max size | 10,000 characters | Large enough to be useful, small enough for context |
| Who gets it | Subagents only | Feature designed for agent lifecycle |

## Implementation

### 1. Display on /whoami

**File**: [app/views/whoami/index.md.erb](app/views/whoami/index.md.erb)

Add after the capabilities section (around line 53), before studios:

```erb
<% scratchpad = @current_user.agent_configuration&.dig("scratchpad") %>
## Your Scratchpad

<% if scratchpad.present? %>
<%= scratchpad %>
<% else %>
_Your scratchpad is empty. Use the `update_scratchpad` action to save notes for your future self._
<% end %>
```

### 2. Add Action Definition

**File**: [app/services/actions_helper.rb](app/services/actions_helper.rb)

Add to `ACTION_DEFINITIONS` hash:

```ruby
"update_scratchpad" => {
  description: "Update your scratchpad with notes for your future self",
  params_string: "(content)",
  params: [
    { name: "content", type: "string", description: "The new scratchpad content (max 10000 chars). Replaces existing content." },
  ],
  authorization: :self_subagent,
},
```

Add to `@@actions_by_route`:

```ruby
"/whoami" => {
  controller_actions: ["whoami#index"],
  actions: [
    { name: "update_scratchpad", params_string: ACTION_DEFINITIONS["update_scratchpad"][:params_string], description: ACTION_DEFINITIONS["update_scratchpad"][:description] },
  ],
},
```

### 3. Add Authorization Type

**File**: [app/services/action_authorization.rb](app/services/action_authorization.rb)

Add to `AUTHORIZATION_CHECKS`:

```ruby
self_subagent: lambda { |user, context|
  return false unless user&.subagent?

  target_user = context[:target_user]
  # No target_user context = permissive for listing (shows action to subagents)
  return true unless target_user

  target_user.id == user.id
},
```

### 4. Add Routes

**File**: [config/routes.rb](config/routes.rb)

Add after the existing `get 'whoami'` route:

```ruby
get 'whoami/actions' => 'whoami#actions_index'
get 'whoami/actions/update_scratchpad' => 'whoami#describe_update_scratchpad'
post 'whoami/actions/update_scratchpad' => 'whoami#execute_update_scratchpad'
```

### 5. Add Controller Methods

**File**: [app/controllers/whoami_controller.rb](app/controllers/whoami_controller.rb)

Add methods:

```ruby
def actions_index
  render_actions_index(ActionsHelper.actions_for_route("/whoami"))
end

def describe_update_scratchpad
  return render plain: "403 Unauthorized", status: 403 unless current_user&.subagent?
  render_action_description(ActionsHelper.action_description("update_scratchpad"))
end

def execute_update_scratchpad
  return render plain: "403 Unauthorized", status: 403 unless current_user&.subagent?

  content = params[:content].to_s

  if content.length > 10_000
    return render_action_error({
      action_name: "update_scratchpad",
      error: "Scratchpad content exceeds maximum length of 10000 characters",
    })
  end

  current_user.agent_configuration ||= {}
  current_user.agent_configuration["scratchpad"] = content.presence
  current_user.save!

  render_action_success({
    action_name: "update_scratchpad",
    result: "Scratchpad updated successfully.",
  })
end
```

### 6. Add End-of-Task Scratchpad Prompt

**File**: [app/services/agent_navigator.rb](app/services/agent_navigator.rb)

Add a method to prompt for scratchpad update and call it at all 4 exit points.

**New method** (add after `parse_action`):

```ruby
sig { params(task: String, outcome: String, final_message: String).void }
def prompt_for_scratchpad_update(task:, outcome:, final_message:)
  # Build prompt asking agent to update their scratchpad
  scratchpad_prompt = <<~PROMPT
    ## Task Complete

    **Task**: #{task}
    **Outcome**: #{outcome}
    **Summary**: #{final_message}
    **Steps taken**: #{@steps.count}

    Please update your scratchpad with any context that would help your future self.
    This might include:
    - Key learnings from this task
    - Important context discovered
    - Work in progress or follow-ups needed
    - User preferences observed

    Respond with JSON:
    ```json
    {"scratchpad": "your updated scratchpad content"}
    ```

    If you have nothing to add, respond with:
    ```json
    {"scratchpad": null}
    ```
  PROMPT

  @messages << { role: "user", content: scratchpad_prompt }
  result = @llm.chat(messages: @messages, system_prompt: system_prompt)

  # Parse and save scratchpad update
  begin
    json_match = result.content.match(/```json\s*(.*?)\s*```/m) || result.content.match(/\{.*\}/m)
    if json_match
      json_str = json_match[1] || json_match[0]
      parsed = JSON.parse(json_str.to_s)
      if parsed["scratchpad"].present?
        content = parsed["scratchpad"].to_s[0, 10_000] # Enforce max length
        @user.agent_configuration ||= {}
        @user.agent_configuration["scratchpad"] = content
        @user.save!
        add_step("scratchpad_update", { content: content.truncate(100) })
      end
    end
  rescue JSON::ParserError, StandardError => e
    # Log but don't fail the task for scratchpad errors
    add_step("scratchpad_update_failed", { error: e.message })
  end
end
```

**Modify exit points** in `run_with_token`:

1. **"done" case** (line ~112):
```ruby
when "done"
  add_step("done", { message: action[:message] })
  prompt_for_scratchpad_update(
    task: task,
    outcome: "completed",
    final_message: action[:message] || "Task completed"
  )
  return Result.new(...)
```

2. **"error" case** (line ~120):
```ruby
when "error"
  add_step("error", { message: action[:message] })
  prompt_for_scratchpad_update(
    task: task,
    outcome: "error",
    final_message: action[:message] || "Agent encountered an error"
  )
  return Result.new(...)
```

3. **Max steps reached** (line ~131):
```ruby
# Hit max steps
prompt_for_scratchpad_update(
  task: task,
  outcome: "incomplete - max steps reached",
  final_message: "Reached maximum steps (#{max_steps}) without completing task"
)
Result.new(...)
```

4. **Exception caught** (line ~137):
```ruby
rescue StandardError => e
  add_step("error", { message: e.message, backtrace: e.backtrace&.first(5) })
  prompt_for_scratchpad_update(
    task: task,
    outcome: "exception",
    final_message: "Agent encountered an error: #{e.message}"
  )
  Result.new(...)
```

## Files Changed

| File | Change |
|------|--------|
| `app/views/whoami/index.md.erb` | Add scratchpad display section |
| `app/services/actions_helper.rb` | Add action definition and route mapping |
| `app/services/action_authorization.rb` | Add `:self_subagent` authorization |
| `config/routes.rb` | Add whoami action routes |
| `app/controllers/whoami_controller.rb` | Add action methods |
| `app/services/agent_navigator.rb` | Add `prompt_for_scratchpad_update` method, call at all exit points |
| `test/controllers/whoami_controller_test.rb` | Add scratchpad controller tests |
| `test/services/agent_navigator_test.rb` | Add scratchpad prompting tests |

## Testing

### Manual Testing

1. Start app, log in as a subagent (or impersonate one)
2. Navigate to `/whoami` - should see empty scratchpad section
3. Navigate to `/whoami/actions` - should see `update_scratchpad` action
4. Execute action with content - should succeed
5. Navigate to `/whoami` - should see updated scratchpad
6. Run a task via subagent - verify scratchpad prompt at end of task
7. Verify scratchpad persists to next task run

### Automated Tests

**Controller tests** (`test/controllers/whoami_controller_test.rb`):
- Test scratchpad displays for subagents
- Test scratchpad hidden for person users
- Test update action succeeds for subagents
- Test update action returns 403 for non-subagents
- Test max length validation

**AgentNavigator tests** (`test/services/agent_navigator_test.rb`):
- Test scratchpad prompt called after successful "done"
- Test scratchpad prompt called after "error"
- Test scratchpad prompt called after max steps reached
- Test scratchpad update persists to user record
- Test scratchpad update errors don't fail the task
