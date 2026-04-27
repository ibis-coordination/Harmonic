# Search Scope Refactor for Private Workspaces

## Context

Now that private workspaces exist, the `scope:` search operator needs updating. Currently `scope:private` means "all non-public collectives I belong to," which lumps shared collectives together with the user's truly private workspace. The term "private" should mean truly private — the user's workspace only.

## Design

Three-way scope split: `public`, `shared`, `private`.

| Scope value | What it searches |
|---|---|
| `public` | Main collective only (unchanged) |
| `shared` | Non-public, non-workspace collectives the user belongs to |
| `private` | User's private workspace only |
| (no scope) | Everything the user has access to (unchanged) |

`shared` was chosen over `collectives` because it intuitively sits between `public` and `private` — it's clearly non-public and non-private.

## Changes

### search_query_parser.rb

Update the `scope` operator values:

```ruby
"scope" => { values: ["public", "shared", "private"], multi: false },
```

### search_query.rb — `accessible_collective_ids`

Update the `case scope` block:

```ruby
case scope
when "public"
  [main_id].compact
when "shared"
  member_ids - [main_id].compact - workspace_ids
when "private"
  workspace_ids
else
  member_ids
end
```

Where `workspace_ids` is the user's private workspace IDs (should be at most one per tenant):

```ruby
workspace_ids = @current_user.collectives
  .where(tenant_id: @tenant.id, collective_type: "private_workspace")
  .pluck(:id)
```

### Help docs and search view

- Update `app/views/help/search.md.erb` — change `scope:` values to `public, shared, private`
- Update `app/views/search/show.md.erb` — same
- Update `app/views/search/show.html.erb` — if scope values are displayed anywhere

### Tests

- `scope:private` returns only workspace content
- `scope:shared` returns non-public, non-workspace content
- `scope:public` unchanged
- No scope returns everything (unchanged)
- Verify negation works: `-scope:private` excludes workspace content

## Files to modify

| File | Change |
|------|--------|
| `app/services/search_query_parser.rb` | Update scope values |
| `app/services/search_query.rb` | Update `accessible_collective_ids` logic |
| `app/views/search/show.md.erb` | Update scope operator docs |
| `app/views/help/search.md.erb` | Update scope operator docs |
| `test/services/search_query_parser_test.rb` | Update/add scope tests |
| `test/services/search_query_test.rb` | Add scope filtering tests |
