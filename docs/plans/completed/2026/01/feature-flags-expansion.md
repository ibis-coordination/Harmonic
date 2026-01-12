# Feature Flag System Expansion Plan

**Status**: Completed
**Branch**: `feature/feature-flags-expansion`
**Commit**: `682c70f`

## Overview

Implement a hierarchical feature flag system with three levels (App → Tenant → Studio) where:
- Features must be enabled at **all higher levels** to be available (cascading)
- Flag definitions and **app-level values are fixed in config** (no database, no runtime toggle)
- Admin UIs at **tenant and studio levels** allow toggling based on admin permissions

## Features Gated

| Flag | Description |
|------|-------------|
| `api` | API access for programmatic integrations and AI agents |
| `file_attachments` | File attachments on notes, decisions, and commitments |

## Files Created

| File | Purpose |
|------|---------|
| `config/feature_flags.yml` | Flag definitions with app-level values and defaults |
| `app/services/feature_flag_service.rb` | Central service with cascade logic |
| `app/models/concerns/has_feature_flags.rb` | Shared concern for Tenant/Studio |
| `db/migrate/20260112131013_migrate_feature_flags_settings.rb` | Data migration |
| `test/services/feature_flag_service_test.rb` | Service tests |

## Files Modified

| File | Changes |
|------|---------|
| `app/models/tenant.rb` | Include HasFeatureFlags, add `feature_enabled?` |
| `app/models/studio.rb` | Update to use FeatureFlagService |
| `app/controllers/admin_controller.rb` | Handle feature flags in tenant settings |
| `app/controllers/studios_controller.rb` | Handle feature flags in studio settings |
| `app/views/admin/tenant_settings.html.erb` | "Features Enabled" section |
| `app/views/admin/tenant_settings.md.erb` | "Features Enabled" section |
| `app/views/studios/settings.html.erb` | "Features Enabled" section |
| `app/views/studios/settings.md.erb` | "Features Enabled" section |

## Key Design Decisions

1. **Cascading**: Features must be enabled at all higher levels (App → Tenant → Studio)
2. **App-level fixed in config**: No runtime toggle for app-level flags
3. **Hidden when disabled**: Features disabled at higher levels don't appear in lower-level UIs
4. **Legacy fallback**: Backward compatibility with old `api_enabled` and `allow_file_uploads` settings
5. **YAML config**: Flag definitions in `config/feature_flags.yml` with metadata (name, description, defaults)

## Config Structure

```yaml
feature_flags:
  api:
    name: "API Access"
    description: "Enables API access for programmatic integrations and AI agents"
    app_enabled: true
    default_tenant: false
    default_studio: false

  file_attachments:
    name: "File Attachments"
    description: "Allows users to attach files to notes, decisions, and commitments"
    app_enabled: true
    default_tenant: true
    default_studio: true
```

## Service Methods

```ruby
FeatureFlagService.app_enabled?(flag_name)
FeatureFlagService.tenant_enabled?(tenant, flag_name)
FeatureFlagService.studio_enabled?(studio, flag_name)
FeatureFlagService.all_flags
FeatureFlagService.flag_metadata(flag_name)
```

## Verification

- All 823 tests pass
- Sorbet type check passes
- RuboCop lint passes
