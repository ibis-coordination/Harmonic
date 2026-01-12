# Codebase Patterns Analysis

This document compares the patterns in this codebase to common patterns seen in other Rails applications, highlighting what's familiar and what's distinctive.

## Familiar Patterns

**Standard Rails conventions**: The codebase follows conventional Rails patterns - RESTful controllers, Active Record models, concerns for shared behavior, service objects for business logic. The model structure with `belongs_to`, `has_many`, validations, and callbacks is typical.

**Multi-tenancy via subdomains**: Subdomain-based tenancy with thread-local scoping (`Thread.current[:tenant_id]`) is a well-established pattern in many SaaS applications. The `default_scope` approach for automatic filtering is common, though some prefer explicit scoping to avoid gotchas.

**Concern-based composition**: Using concerns like `Linkable`, `Commentable`, `Attachable` to compose model behavior is standard Rails practice. The pattern of including multiple concerns in a model to add capabilities is everywhere.

**Hotwire stack**: Turbo + Stimulus with TypeScript controllers is the modern Rails way. The controller structure with `static targets`, typed target declarations, and async methods follows Stimulus conventions.

**Polymorphic associations**: The `commentable` and `linkable` polymorphic patterns are bread-and-butter Rails for cross-model relationships.

---

## Distinctive Patterns

**Dual interface (HTML + Markdown)**: This is unusual. Most apps have HTML views and JSON APIs. Having Markdown views specifically designed for LLM consumption with YAML frontmatter and `[Actions]` sections is forward-thinking - this pattern is rare elsewhere.

**Truncated IDs in URLs**: The `HasTruncatedId` pattern (see `app/models/concerns/has_truncated_id.rb`) using 8 characters from UUIDs for URLs (`/n/a1b2c3d4`) is a nice balance between readability and uniqueness. Most apps use either sequential IDs or full UUIDs.

**Non-persisted Cycle model**: Computing cycles dynamically from tempo settings rather than storing them as database records is unconventional. Most apps would create a `cycles` table. The in-memory approach is lighter but unusual.

**Two-dimensional voting**: The acceptance + preference voting model in `Decision` (see `app/models/decision.rb`) is uncommon. Most voting systems are single-dimensional (upvote/downvote or star ratings).

**Critical mass/quorum**: `Commitment` (see `app/models/commitment.rb`) requiring a threshold before activation addresses the collective action problem - this isn't commonly baked into a social app's core model.

**Representation sessions**: Users acting on behalf of studios with nested representation (`RepresentationSession`, `RepresentationSessionAssociation`) is a sophisticated collective agency pattern that's rare. Most apps have simple user-owns-content models.

**Bidirectional links as first-class**: The `Link` model (see `app/models/link.rb`) creating an explicit knowledge graph with automatic backlink tracking is more like Obsidian/Roam than typical social apps.

---

## Code Quality Observations

**Strengths**:
- Strong typing (Sorbet + TypeScript strict mode)
- Consistent code style
- Thorough test helpers
- Good documentation (CLAUDE.md, PHILOSOPHY.md, AGENTS.md)

**Common challenges**:
- Large controller (`ApplicationController` at ~600 lines)
- Large service classes (`ApiHelper` at ~420 lines)
- Typical "fat controller/service" evolution that happens in growing codebases

---

## Conceptual Framework

The conceptual framework (OODA loop, biological metaphors like quorum sensing) gives the domain model unusual coherence compared to most social apps that grow organically without a unifying theory.

Key conceptual mappings:
- **Observe**: Notes (posts/content)
- **Orient**: Cycles (time-bounded windows) and Links (bidirectional references)
- **Decide**: Decisions (group voting with acceptance + preference)
- **Act**: Commitments (action pledges with critical mass thresholds)

---

*Last updated: January 2026*
