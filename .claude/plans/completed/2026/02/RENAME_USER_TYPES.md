# Plan: Rename User Types (person → human, subagent → ai_agent)

## Summary

Rename user types throughout the Harmonic codebase:
- `"person"` → `"human"` (database value and code references)
- `"subagent"` → `"ai_agent"` (database value and code references)
- UI text: "Subagent" → "AI Agent"

## Decisions

- **No backwards compatibility**: Old URLs will return 404 (clean break)
- **UI text**: Use "AI Agent" (e.g., "My AI Agents", "Create AI Agent")
- **Learn page**: Rename `/learn/subagency` → `/learn/ai-agency`

## Scope

~150 files affected across models, controllers, services, views, JavaScript, CSS, tests, and documentation.

---

## Phase 1: Database Migrations

Create 3 migrations:

1. **Rename user_type values**
   - `person` → `human`
   - `subagent` → `ai_agent`

2. **Rename task run tables and columns**
   - `subagent_task_runs` → `ai_agent_task_runs`
   - `subagent_task_run_resources` → `ai_agent_task_run_resources`
   - `subagent_id` → `ai_agent_id`

3. **Update column default**
   - Default from `'person'` to `'human'`

---

## Phase 2: Models

### User Model (`app/models/user.rb`)
- Update validation: `["human", "ai_agent", "superagent_proxy"]`
- Rename methods: `person?` → `human?`, `subagent?` → `ai_agent?`
- Rename association: `has_many :subagents` → `has_many :ai_agents`
- Update validation method: `subagent_must_have_parent` → `ai_agent_must_have_parent`

### Rename Model Files
- `subagent_task_run.rb` → `ai_agent_task_run.rb` (class `AiAgentTaskRun`)
- `subagent_task_run_resource.rb` → `ai_agent_task_run_resource.rb`

---

## Phase 3: Controllers

### Rename Controller
- `subagents_controller.rb` → `ai_agents_controller.rb`

### Update Other Controllers
- `application_controller.rb`: `current_person_user` → `current_human_user`
- `users_controller.rb`, `studios_controller.rb`: update subagent references
- Admin controllers: update user type display

---

## Phase 4: Services

- `capability_check.rb`: Rename `SUBAGENT_*` constants to `AI_AGENT_*`, update action names
- `api_helper.rb`: `create_subagent` → `create_ai_agent`
- `action_authorization.rb`, `actions_helper.rb`: update references

---

## Phase 5: Routes

Update `config/routes.rb`:
- `/subagents` → `/ai-agents`
- Route helpers: `subagent_*_path` → `ai_agent_*_path`
- No redirects from old URLs (clean break)

---

## Phase 6: Views

### Rename Directory
- `app/views/subagents/` → `app/views/ai_agents/`

### Rename Learn Page
- `app/views/learn/subagency.md.erb` → `app/views/learn/ai_agency.md.erb`

### Update UI Text (39+ files)
- "Subagent" → "AI Agent" in all user-facing text
- Update badges, labels, headings, descriptions
- Shared partials: `_team.html.erb`, `_created_by.html.erb`, etc.

---

## Phase 7: JavaScript/TypeScript

### Rename Files
- `subagent_manager_controller.ts` → `ai_agent_manager_controller.ts`
- `subagent_superagent_adder_controller.ts` → `ai_agent_superagent_adder_controller.ts`
- `subagent_mode_controller.ts` → `ai_agent_mode_controller.ts`

### Update Registrations
- `data-controller="subagent-manager"` → `data-controller="ai-agent-manager"`

---

## Phase 8: CSS

Update `app/assets/stylesheets/pulse/_components.css`:
- `.pulse-subagent-*` → `.pulse-ai-agent-*` (15+ classes)

---

## Phase 9: Feature Flags

Update `config/feature_flags.yml`:
- `subagents:` → `ai_agents:`
- Update `Tenant#subagents_enabled?` → `Tenant#ai_agents_enabled?`

---

## Phase 10: Tests

### Rename Test Files
- `subagent_capability_test.rb` → `ai_agent_capability_test.rb`
- `subagent_task_run_resource_test.rb` → `ai_agent_task_run_resource_test.rb`
- etc.

### Update Test Content
- `user_type: "person"` → `user_type: "human"`
- `create_subagent` → `create_ai_agent` in test helper

---

## Phase 11: Sorbet & Documentation

- Regenerate Sorbet RBI files: `bundle exec tapioca dsl`
- Update documentation files

---

## Verification

1. Run database migrations
2. Run full test suite: `./scripts/run-tests.sh`
3. Run type checker: `docker compose exec web bundle exec srb tc`
4. Run linter: `docker compose exec web bundle exec rubocop`
5. Manual testing:
   - Login as human user
   - Create AI agent
   - Run AI agent task
   - Add/remove AI agent from studio
   - Verify admin views
