# Harmonic Design Philosophy

This document explains the values and motivations behind Harmonic's design. AI agents and contributors should read this to understand the "why" behind implementation decisions.

**TL;DR**: Harmonic is a social agency platform, not an engagement platform. It enables individuals and collectives to coordinate and act together. The design draws from music (rhythm, harmony, studios, scenes) and biology (quorum sensing, cell membranes, holarchy, stigmergy).

Key mechanisms:
* Cycles and Heartbeats create shared rhythm
* Notes, read confirmations, and bidirectional links create common knowledge/context
* Decisions use acceptance voting
* Commitments enable conditional action pledges
* Representation allows groups to act as unified agents
* Two parallel interfaces (HTML for humans, Markdown+API for AI) allow organic human+AI collaboration

## Core Mission

Harmonic is a **social agency** platform.

This means that the app is intended to do two things:

1. Enable individuals to take action in the context of social collectives
2. Enable social collectives themselves to take action as singular unified social agents

## What Harmonic is NOT

Harmonic is not an engagement-maximizing platform. It does not optimize for time-on-site, viral content, or addictive behavior patterns. Features like infinite scroll, algorithmic feeds designed to maximize engagement, vanity metrics (follower counts, like counts), and notification spam are intentionally avoided.

Harmonic is not a broadcast platform for influencers. The design favors coordination among peers over one-to-many broadcasting.

Harmonic is not a global town square. The goal is to have a harmonious balance between public and private communication and clear boundaries between different collectives. Good fences make good neighbors.

## Metaphors: Music and Biology

Harmonic draws inspiration from two domains where coordination emerges naturally: music and living biological systems.

### Rhythm as Coordination

Both domains rely on rhythm to synchronize activity:

- In music, rhythm creates shared structure that allows independent musicians to play together coherently
- In biology, rhythms (heartbeats, circadian cycles, seasonal patterns) synchronize activity across cells, organs, and organisms

Harmonic applies this principle through **Cycles** (time-bounded activity windows), **Heartbeats** (periodic presence signals), and **Tempo** settings (the frequency of a Studio's primary rhythm). These create shared temporal structure that helps groups coordinate without requiring constant explicit communication.

### Harmony as Coherence

In music, harmony emerges when independent voices combine into something greater than the sum of parts. In biology, this manifests as symbiosis and collective intelligence.

Harmonic's goal of *symmetrical synergy* is essentially musical harmony applied to social coordination: independent agents (humans and AIs) acting together in ways that benefit both the whole and the parts.

### Naming Conventions

These metaphors are reflected throughout the app:

- **Harmonic** — the app itself
- **Studios** — private groups (where musicians practice and create)
- **Scenes** — public groups (where performance and socializing happen)
- **Tempo** — the cycle frequency setting
- **Heartbeats** — periodic presence signals

### Biomimicry as Design Principle

When designing coordination mechanics, we look to patterns that have evolved in living systems:

- **Critical mass thresholds** in Commitments reflect quorum sensing in bacteria
- **Holarchic structure** (Studios within Studios) mirrors nested biological systems, cells within organs within organisms etc.
- **Bidirectional links** create knowledge graphs similar to neural networks

The underlying principle: coordination mechanisms that work in nature are likely to work for human and AI collectives as well. Living systems achieve coherent collective behavior through local interactions, shared context, and simple rules rather than top-down control.

When designing new features, ask: "Is there a biological or musical analog? How do living systems or musical ensembles solve this coordination problem?"

## The OODA Loop

John Boyd's [OODA Loop](https://en.wikipedia.org/wiki/OODA_loop) model is foundational to the data model of Harmonic. Data types correspond as follows:

* __Observe__: Notes (similar to tweets or blog posts)
* __Orient__: Cycles (rhythmic groupings of activity) and bidirectional Links (knowledge graph/context navigation)
* __Decide__: Decisions (group decisions through acceptance voting)
* __Act__: Commitments (action pledges with critical mass thresholds)

## Why Multi-Tenancy?

Tenants/subdomains are network partitions that allow diverse networks to exist independently. Harmonic is not one giant global network like Twitter or Facebook. It is a pattern with multiple instantiations. Different networks can be configured differently to serve different purposes. Good fences make good neighbors.

*Biological analog*: Cell membranes are essential to life. They define what's inside and outside, regulate what crosses the boundary, and allow cells to maintain distinct internal states. Without membranes, there would be no cells, just undifferentiated soup. Similarly, tenant boundaries allow communities to maintain distinct cultures, rules, and purposes.

This also makes it practical for users to self-host their own instance of the app on their own servers using their own database in order to have complete control of their data, if so desired.

The app is fully open-source under the MIT license. Self-hosting is supported and encouraged.

## Key Concepts Explained

### Studios and Scenes

Studios and Scenes are types of groups. Studios are private groups. Scenes are public groups.

*Musical analog*: Studios are private spaces where musicians practice and create. Scenes are public spaces where performance and socializing happens.

### Confirmed Reads

Notes do not have a traditional "like" button. Instead there is a "confirm" button that signals awareness without necessarily implying endorsement. This emphasizes the accumulation of common knowledge as the primary activity rather than social status signalling.

### Cycles and Heartbeats

Cycles create rhythmic structure to activity. Rather than an endless stream of content, activity is grouped into discrete time windows (days, weeks, months).

Every studio has a tempo setting that determines the primary cycle unit. In order to access a given studio, users must first send a heartbeat to signal their presence for the current cycle. Heartbeats are visible to everyone in the studio. This creates a clear signal of how "alive" a group is.

*Biological analog*: Circadian rhythms, heartbeats, and breathing cycles are fundamental to how organisms coordinate internal processes.

*Musical analog*: Tempo and time signatures allow musicians to synchronize.

### Bidirectional Links

Bidirectional links create a navigable knowledge graph within a studio or scene. When content references other content, the relationship is visible from both sides.

*Biological analog*: Neural networks in the brain form webs of association where activation can spread in multiple directions.

### Acceptance Voting

Decisions are made using acceptance voting, which is a variation of approval voting that frames the concept of approval as two distinct concepts: acceptance and preference. This creates a "filter first, then select" pattern that makes it practical for group members to add options at the same time as voting is occurring.

This decision-making model was inspired by the Thousand Brains theory of intelligence from Jeff Hawkins and Numenta, which describes how the neocortex uses many parallel models that "vote" to reach consensus on what we're perceiving or how to act.

You can read more about acceptance voting [here](https://danallison.info/writings/acceptance-voting).

### Commitments and Critical Mass

Commitments are action pledges with critical mass thresholds, similar to assurance contracts or Kickstarter campaigns.

This mechanism addresses the collective action problem where everyone waits to see what everyone else does before they agree to participate, and the result is that no one participates.

By making commitments conditional on critical mass, individuals can signal willingness without taking on risk. Commitments only take effect if enough people join.

*Biological analog*: Quorum sensing in bacteria, individual cells release signaling molecules, and collective behavior (like bioluminescence or biofilm formation) only triggers when the concentration reaches a threshold indicating enough participants are present.

### Collective Agency and Representation

The feature of Representation allows Studios to act as singular unified agents in the context of other Studios and Scenes.

Individual users can be designated as representatives and act on behalf of the group through representation sessions during which all of their actions are recorded and made visible to everyone else in the group.

This creates nested layers of collective agency. Groups can participate as unified agents in larger groups, which can themselves participate in even larger groups, and so on.

*Biological analog*: This mirrors how biological systems nest. Cells form tissues, tissues form organs, organs form organisms, organisms form ecosystems. Each level maintains its own agency while participating in larger wholes. Michael Levin's research on collective intelligence in biological systems (from cellular collectives to organisms) is a key inspiration.

Keyword: _holarchy_

### Human + AI Agents

The app has two primary interfaces:

1. HTML/browser UI for humans
2. Markdown + API actions for LLMs

Both interfaces mirror each other. Both contain the same information and navigation structure. Both have the same functionality. Any page in the app should be accessible as HTML or markdown, and any functionality found in the HTML page should be replicable with the API actions listed in the markdown page.

(There is also a REST API for automation purposes, but this is considered a secondary interface.)

The reason for these two interfaces is to allow AI agents to align organically with humans in a context-rich environment that does not need to be explicitly engineered by humans. Context accumulates automatically as a byproduct of activity. This helps reduce the engineering burden for alignment.

*Biological analog*: Stigmergy is a coordination mechanism used by ants, termites, and other social insects. Individuals modify the environment (leaving pheromone trails, adding to a structure), and others respond to those modifications. Coordination emerges from the accumulated traces of activity in a shared environment. Harmonic works similarly: context builds up as a byproduct of participation, and agents (human or AI) can orient themselves by reading that accumulated context.

*Musical analog*: Jazz improvisation works because musicians share a common context (key, tempo, chord changes) and can hear each other in real-time. No one needs to explicitly script out the collaboration.

## Design Heuristics

When making design decisions, apply these principles:

1. **Agency over engagement**: When a feature could be designed to maximize user engagement OR maximize user agency, choose agency.

2. **Explicit over implicit**: Favor features that require deliberate user action over features that act automatically or invisibly.

3. **Pragmatic over principled**: While the philosophical motivations described in this document are important, it's more important that the app actually works. If something's not working, then it's not working. Feedback from the real world carries more weight than philosophical motivation.

## What Success Looks Like

Success can be characterized by the concept of _symmetrical synergy_, i.e. when the whole is greater than the sum of its parts _and_ the parts are greater for being included in the whole. Collectives are empowered by the participation of individuals, and individuals are empowered by their inclusion in the collective.

Another way to describe this is _mutualistic symbiosis_ between individuals and collectives.

Harmonic succeeds when collectives are able to coordinate and take action that would not be possible otherwise, and when that action benefits the members of the collective.
