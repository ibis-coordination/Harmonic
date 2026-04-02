# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.2] - 2026-04-02

### Security

- Bump Rails from 7.2.3 to 7.2.3.1 (activesupport, actionview, activestorage)
- Bump rack from 2.2.22 to 2.2.23
- Bump bcrypt from 3.1.20 to 3.1.22
- Bump json from 2.18.0 to 2.19.2

### Changed

- Pin connection_pool < 3 for Rails 7.2.x compatibility

### Dependencies

- Bump hono from 4.12.5 to 4.12.7 (harmonic-agent, mcp-server)
- Bump picomatch from 4.0.3 to 4.0.4 (harmonic-agent, mcp-server)
- Bump path-to-regexp from 8.3.0 to 8.4.0 (mcp-server)
- Bump effect from 3.19.14 to 3.21.0 (harmonic-agent)

## [1.4.1] - 2026-03-06

### Fixed

- Fix note edit form routing error for main collective items
- Fix OAuth login failing on iOS mobile browsers
- Fix top-right menu misalignment on mobile

### Changed

- Add proximity-ranked content timelines to homepage and user profiles
- Move collectives/subdomains from homepage to top-right menu
- Remove "Schedule Reminder" button from notifications page
- Collapse header search to icon-only on mobile to prevent overflow
- UX fixes: sidebar component, header creation button, visibility hints

### Dependencies

- Bump @hono/node-server from 1.19.9 to 1.19.10 (harmonic-agent, mcp-server)
- Bump hono from 4.11.9 to 4.12.5 (harmonic-agent, mcp-server)
- Bump rollup from 4.55.1 to 4.59.0 (harmonic-agent, mcp-server)
- Bump express-rate-limit from 8.2.1 to 8.3.0 (mcp-server)
- Bump nokogiri from 1.18.9 to 1.19.1

## [1.4.0] - 2026-02-28

### Changed

- Unify studios/scenes as collectives (remove collective_type column)
- Add search scope filtering with scope operator
- Remove explore collectives links and fix index page image sizing
- Clean up references to removed collective types in UI and docs
