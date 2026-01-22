# Feedback System Plan

**Status**: Placeholder — to be developed after AI agent context routes are complete

## Overview

A general-purpose feedback collection system that allows users to document what's working and what's not working. Feedback is how the system as a whole improves over time.

## Key Concept

Feedback should be addressable to different recipients depending on what the feedback is about:

| Feedback For | Purpose |
|--------------|---------|
| App developers | Bugs, feature requests, general UX issues |
| Tenant admins | Tenant-level policies, configuration, community issues |
| Studio admins | Studio-specific issues, moderation, norms |
| Parents of subagents | Subagent behavior, concerns, suggestions |
| Specific users | Direct feedback on interactions or contributions |

## Why This Matters

- **Closed loop**: Without feedback, problems go unaddressed and good patterns go unrecognized
- **Distributed responsibility**: Different issues need different people to address them
- **Transparency**: Making feedback visible (where appropriate) helps everyone learn
- **Accountability**: Feedback on subagents flows to parents; feedback on studios flows to admins

## Open Questions (For Later)

- Should feedback be public, private, or configurable?
- How does feedback relate to existing features (notes, decisions)?
- Should there be structured categories or free-form?
- How do recipients get notified?
- Should there be a resolution/acknowledgment flow?
- How does this interact with the accountability structure?

## Implementation

To be designed after completing the AI agent context routes plan.
