# Social Proximity Algorithm Implementation Plan

## Overview

Implement a **Personalized PageRank (PPR)** algorithm to compute "social proximity" between users based on shared **activity group** membership. This provides a relative, viewer-centric measure of connection rather than a global reputation score.

### Key Insight: Expanded Definition of "Groups"

In the original PPR algorithm, groups are static organizational units (like studios). We expand this to include **activity-based groups** - ephemeral collections of users who have engaged with the same content:

| Group Type | Description | Signal Strength |
|------------|-------------|-----------------|
| **Superagent** | Studio or Scene membership | Strong (ongoing relationship) |
| **Note Readers** | Users who confirmed reading a note | Medium (shared attention) |
| **Decision Voters** | Users who voted on a decision | Medium (shared deliberation) |
| **Commitment Joiners** | Users who joined a commitment | Strong (shared action) |
| **Cycle Heartbeats** | Users active in a superagent during a cycle | Medium (temporal co-presence) |

This captures both **structural affinity** (we belong to the same spaces) and **behavioral affinity** (we engage with the same content).

### Key Concepts from the Source Conversation

1. **Random walks on bipartite graph** (users ↔ groups) with teleport-back-to-source
2. **Adamic-Adar weighting** - smaller groups count more (1/log(size))
3. **Pairwise affinity** - relative to the viewer, not a global score
4. **Established algorithms**: Personalized PageRank, Adamic-Adar Index, SimRank

### Design Philosophy: Balancing vs Reinforcing Feedback Loops

The Adamic-Adar weighting (`1/log(size)`) creates a fundamentally different dynamic than traditional social media algorithms:

| Group Size | Weight | Relative Signal |
|------------|--------|-----------------|
| 2 | ~1.44 | Very strong |
| 10 | ~0.43 | Moderate |
| 1,000 | ~0.14 | Weak |
| 1,000,000 | ~0.07 | Nearly noise |

**Traditional social media (reinforcing feedback loop):**
```
Content gets attention → Algorithm amplifies → More attention → More amplification → ...
```
This creates winner-take-all dynamics, popularity cascades, and incentivizes content optimized for mass appeal.

**This algorithm (balancing feedback loop):**
```
Content gets attention → Group of readers grows → Weight decreases → Less influence on proximity → ...
```
As something becomes popular, its signal strength *diminishes*. The algorithm naturally dampens viral spread rather than amplifying it.

**What this optimizes for:**

Instead of surfacing "what's popular" (which everyone already knows about), it surfaces "what's meaningfully shared" - the small studio you're both in, the obscure note only three people read, the niche decision you both voted on. These are the signals of genuine affinity, not mass behavior.

This aligns with Harmonic's design philosophy of neutral social mechanics (read confirmations instead of likes, etc.): the system measures *attention* and *co-presence* rather than *approval* and *popularity*. The weighting ensures that rare, selective attention counts more than abundant, undifferentiated attention.

**Designing for resonance over reach.**

## Mapping to Harmonic's Architecture

| Algorithm Concept | Harmonic Implementation |
|-------------------|-------------------------|
| User | `User` |
| Group | Abstract - multiple sources (see below) |
| Membership | Varies by group type |
| Group Size | Count of users in that group |

### Group Types and Data Sources

#### 1. Superagent Membership (Studios & Scenes)
```ruby
# Query: Users who are members of a superagent
SuperagentMember.where(superagent_id: X, archived_at: nil).pluck(:user_id)
```
- **Group ID**: `"superagent:#{superagent_id}"`
- **Size**: `SuperagentMember.where(superagent_id: X).count`

#### 2. Note Readers
```ruby
# Query: Users who confirmed reading a note
NoteHistoryEvent.where(note_id: X, event_type: 'read_confirmation').distinct.pluck(:user_id)
```
- **Group ID**: `"note:#{note_id}"`
- **Size**: Count of distinct users with read confirmations

#### 3. Decision Voters
```ruby
# Query: Users who voted on a decision (have votes via participant)
DecisionParticipant.joins(:votes).where(decision_id: X).distinct.pluck(:user_id)
```
- **Group ID**: `"decision:#{decision_id}"`
- **Size**: Count of distinct voters

#### 4. Commitment Joiners
```ruby
# Query: Users who committed to a commitment
CommitmentParticipant.where(commitment_id: X).where.not(committed_at: nil).pluck(:user_id)
```
- **Group ID**: `"commitment:#{commitment_id}"`
- **Size**: Count of committed participants

#### 5. Cycle Heartbeats
```ruby
# Query: Users who sent heartbeats to a superagent during a cycle
# Uses existing Heartbeat model with where_in_cycle scope
cycle = Cycle.new(name: cycle_name, tenant: tenant, superagent: superagent)
Heartbeat.where(tenant_id: X, superagent_id: Y).where_in_cycle(cycle).distinct.pluck(:user_id)
```
- **Group ID**: `"heartbeat:#{superagent_id}:#{cycle_name}"`
- **Size**: Count of distinct users with heartbeats in that cycle

### Multi-Tenancy Consideration

All queries must be scoped to the current `Tenant`. Users in different tenants should not appear in each other's proximity calculations.

## Implementation Phases

### Phase 1: Core Algorithm Service

Create `app/services/social_proximity_calculator.rb`:

```ruby
class SocialProximityCalculator
  WALK_COUNT = 1000        # Number of random walks
  WALK_LENGTH = 6          # Steps per walk (3 user→group→user hops)
  TELEPORT_PROB = 0.15     # Probability of returning to source

  def initialize(source_user, tenant_id:)
    @source = source_user
    @tenant_id = tenant_id
    @landing_counts = Hash.new(0)
  end

  def compute
    preload_graph_data
    WALK_COUNT.times { random_walk }
    normalize_results
  end

  private

  def preload_graph_data
    # Preload all group memberships for 2-hop neighborhood
    # Structure: { user_id => [group_keys] }
    @user_groups = Hash.new { |h, k| h[k] = [] }
    # Structure: { group_key => [user_ids] }
    @group_members = Hash.new { |h, k| h[k] = [] }
    # Structure: { group_key => member_count }
    @group_sizes = {}

    load_superagent_memberships
    load_note_reader_groups
    load_decision_voter_groups
    load_commitment_joiner_groups
    load_heartbeat_groups
  end

  def random_walk
    # Implements the PPR random walk with Adamic-Adar weighting
  end

  def normalize_results
    # Returns { user_id => proximity_score }
  end
end
```

### Phase 1a: Group Loader Methods

```ruby
private

def load_superagent_memberships
  # Get source user's superagents
  source_superagent_ids = SuperagentMember
    .where(tenant_id: @tenant_id, user_id: @source.id, archived_at: nil)
    .pluck(:superagent_id)

  # Get all users in those superagents (1-hop)
  nearby_user_ids = SuperagentMember
    .where(tenant_id: @tenant_id, superagent_id: source_superagent_ids, archived_at: nil)
    .distinct.pluck(:user_id)

  # Get all superagent memberships for 2-hop neighborhood
  SuperagentMember
    .where(tenant_id: @tenant_id, user_id: nearby_user_ids, archived_at: nil)
    .pluck(:user_id, :superagent_id)
    .each do |user_id, superagent_id|
      group_key = "superagent:#{superagent_id}"
      @user_groups[user_id] << group_key
      @group_members[group_key] << user_id
    end

  @group_members.each do |key, members|
    @group_sizes[key] = members.size if key.start_with?("superagent:")
  end
end

def load_note_reader_groups
  # Get notes the source user has read
  source_note_ids = NoteHistoryEvent
    .where(tenant_id: @tenant_id, user_id: @source.id, event_type: 'read_confirmation')
    .pluck(:note_id)

  return if source_note_ids.empty?

  # Get all readers of those notes
  NoteHistoryEvent
    .where(tenant_id: @tenant_id, note_id: source_note_ids, event_type: 'read_confirmation')
    .pluck(:user_id, :note_id)
    .each do |user_id, note_id|
      group_key = "note:#{note_id}"
      @user_groups[user_id] << group_key
      @group_members[group_key] << user_id
    end

  @group_members.each do |key, members|
    @group_sizes[key] = members.uniq.size if key.start_with?("note:")
  end
end

def load_decision_voter_groups
  # Get decisions the source user has voted on
  source_decision_ids = DecisionParticipant
    .joins(:votes)
    .where(tenant_id: @tenant_id, user_id: @source.id)
    .pluck(:decision_id)

  return if source_decision_ids.empty?

  # Get all voters on those decisions
  DecisionParticipant
    .joins(:votes)
    .where(tenant_id: @tenant_id, decision_id: source_decision_ids)
    .where.not(user_id: nil)
    .distinct
    .pluck(:user_id, :decision_id)
    .each do |user_id, decision_id|
      group_key = "decision:#{decision_id}"
      @user_groups[user_id] << group_key
      @group_members[group_key] << user_id
    end

  @group_members.each do |key, members|
    @group_sizes[key] = members.uniq.size if key.start_with?("decision:")
  end
end

def load_commitment_joiner_groups
  # Get commitments the source user has joined
  source_commitment_ids = CommitmentParticipant
    .where(tenant_id: @tenant_id, user_id: @source.id)
    .where.not(committed_at: nil)
    .pluck(:commitment_id)

  return if source_commitment_ids.empty?

  # Get all joiners of those commitments
  CommitmentParticipant
    .where(tenant_id: @tenant_id, commitment_id: source_commitment_ids)
    .where.not(committed_at: nil)
    .where.not(user_id: nil)
    .pluck(:user_id, :commitment_id)
    .each do |user_id, commitment_id|
      group_key = "commitment:#{commitment_id}"
      @user_groups[user_id] << group_key
      @group_members[group_key] << user_id
    end

  @group_members.each do |key, members|
    @group_sizes[key] = members.uniq.size if key.start_with?("commitment:")
  end
end
```

### Phase 2: Random Walk Implementation

```ruby
def random_walk
  current_user_id = @source.id

  (WALK_LENGTH / 2).times do
    # Teleport back to source with probability TELEPORT_PROB
    if rand < TELEPORT_PROB
      current_user_id = @source.id
      next
    end

    # User → Group (weighted by selectivity)
    group_keys = @user_groups[current_user_id]
    return if group_keys.blank?

    group_key = weighted_sample(group_keys)

    # Group → User (uniform random)
    member_ids = @group_members[group_key]
    current_user_id = member_ids.sample

    @landing_counts[current_user_id] += 1 if current_user_id != @source.id
  end
end

def weighted_sample(group_keys)
  # Adamic-Adar: favor smaller groups (weight = 1/log(size))
  weights = group_keys.map do |key|
    size = @group_sizes[key] || 2
    1.0 / Math.log([size, 2].max)
  end

  total = weights.sum
  r = rand * total

  cumulative = 0.0
  group_keys.zip(weights).each do |key, weight|
    cumulative += weight
    return key if r <= cumulative
  end

  group_keys.last
end

def normalize_results
  total = @landing_counts.values.sum.to_f
  return {} if total.zero?

  @landing_counts
    .transform_values { |count| count / total }
    .sort_by { |_id, score| -score }
    .to_h
end
```

### Phase 3: Caching Layer

```ruby
Rails.cache.fetch("proximity:#{tenant_id}:#{source_user_id}", expires_in: 1.day) do
  SocialProximityCalculator.new(source_user, tenant_id: tenant_id).compute
end
```

### Phase 4: User Model Integration

```ruby
class User
  def social_proximity_to(other_user, tenant_id: Tenant.current_id)
    scores = cached_proximity_scores(tenant_id)
    scores[other_user.id] || 0.0
  end

  def proximity_tier_to(other_user, tenant_id: Tenant.current_id)
    score = social_proximity_to(other_user, tenant_id: tenant_id)
    case score
    when 0.05.. then :high      # "Moves in your circles"
    when 0.01.. then :medium    # "Some shared context"
    when 0.001.. then :low      # "Loosely connected"
    else :none
    end
  end

  def most_proximate_users(tenant_id: Tenant.current_id, limit: 20)
    cached_proximity_scores(tenant_id)
      .sort_by { |_id, score| -score }
      .first(limit)
      .map { |id, score| [User.find(id), score] }
  end

  private

  def cached_proximity_scores(tenant_id)
    Rails.cache.fetch("proximity:#{tenant_id}:#{id}", expires_in: 1.day) do
      SocialProximityCalculator.new(self, tenant_id: tenant_id).compute
    end
  end
end
```

### Phase 5: UI Integration

```ruby
# app/helpers/users_helper.rb
def proximity_badge(current_user, other_user)
  tier = current_user.proximity_tier_to(other_user)
  case tier
  when :high   then tag.span("In your circles", class: "proximity-badge proximity-high")
  when :medium then tag.span("Shared context", class: "proximity-badge proximity-medium")
  when :low    then tag.span("Connected", class: "proximity-badge proximity-low")
  else nil
  end
end
```

### Phase 6: API/Markdown Interface

```markdown
## User: @alice
- **Proximity**: High (in your circles)
- **Shared Context**: 3 studios, 5 notes read, 2 decisions voted
```

### Phase 1b: Heartbeat Group Loader

```ruby
def load_heartbeat_groups
  # Get superagents where source user has heartbeats
  source_superagent_ids = Heartbeat
    .where(tenant_id: @tenant_id, user_id: @source.id)
    .distinct
    .pluck(:superagent_id)

  return if source_superagent_ids.empty?

  # For each superagent, group heartbeats by cycle
  # We use the cycle's time window to determine which heartbeats belong together
  source_superagent_ids.each do |superagent_id|
    superagent = Superagent.find(superagent_id)

    # Get the current cycle for this superagent
    cycle = Cycle.new_from_superagent(superagent)
    cycle_key = cycle.name  # e.g., "today", "this-week"

    # Get all users with heartbeats in this superagent during this cycle
    user_ids = Heartbeat
      .where(tenant_id: @tenant_id, superagent_id: superagent_id)
      .where_in_cycle(cycle)
      .distinct
      .pluck(:user_id)

    next if user_ids.size < 2  # Skip if only the source user

    group_key = "heartbeat:#{superagent_id}:#{cycle_key}"
    user_ids.each do |user_id|
      @user_groups[user_id] << group_key
      @group_members[group_key] << user_id
    end
    @group_sizes[group_key] = user_ids.size
  end
end
```

**Note**: The `Heartbeat` model uses `where_in_cycle(cycle)` to filter heartbeats within a cycle's time window (between `cycle.start_date` and `cycle.end_date`). This creates temporal co-presence groups.

## Testing Strategy

### Unit Tests

```ruby
class SocialProximityCalculatorTest < ActiveSupport::TestCase
  # Superagent membership tests
  test "users in same small superagent have high proximity" do
    # Create two users in a 3-person studio
    # Assert proximity > 0.05
  end

  test "users in same large superagent have lower proximity than small one" do
    # Create two users in 100-person scene vs 5-person studio
    # Assert small superagent proximity > large superagent proximity
  end

  # Activity-based group tests
  test "users who read same notes have proximity" do
    # Create two users who both confirmed reading the same note
    # Assert they have measurable proximity
  end

  test "users who voted on same decision have proximity" do
    # Create two users who voted on the same decision
    # Assert they have measurable proximity
  end

  test "users who joined same commitment have proximity" do
    # Create two users who joined the same commitment
    # Assert they have measurable proximity
  end

  test "users with heartbeats in same superagent cycle have proximity" do
    # Create two users with heartbeats in the same superagent during the same cycle
    # Assert they have measurable proximity
  end

  # Combined tests
  test "multiple shared groups increase proximity" do
    # Create two users sharing multiple groups (superagent + note + decision)
    # Assert higher proximity than single shared group
  end

  test "transitive connections are captured" do
    # User A in Superagent 1
    # User B in Superagent 1 and Superagent 2
    # User C in Superagent 2 only
    # Assert A has some proximity to C (via B)
  end

  test "users with no shared groups have zero proximity" do
    # Assert proximity == 0
  end

  test "respects tenant scoping" do
    # Users in different tenants should not have proximity
  end
end
```

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `app/services/social_proximity_calculator.rb` | Create | Core algorithm with multi-source groups |
| `app/models/user.rb` | Modify | Add proximity methods |
| `app/helpers/users_helper.rb` | Modify | Add proximity_badge helper |
| `test/services/social_proximity_calculator_test.rb` | Create | Comprehensive unit tests |

## Open Questions

1. **Where to display proximity?** User cards? Member lists? Search results?
2. **Cache invalidation strategy** - when group membership changes, invalidate affected users?
3. **Performance budget** - is 1000 walks acceptable latency for first request?
4. **Thresholds** - are 0.05/0.01/0.001 the right tier boundaries?
5. **Terminology** - "In your circles", "Shared context", "Connected" - are these the right labels?
6. **Group type weighting** - should superagent membership count more than reading the same note? (Currently all weighted equally by size)
7. **Time decay** - should older activity groups (notes read months ago) count less?
8. **Heartbeat cycle scope** - should we include past cycles or only the current cycle for each superagent?

## References

- [Personalized PageRank (Wikipedia)](https://en.wikipedia.org/wiki/PageRank#Personalized_PageRank)
- [Adamic-Adar Index (2003 paper)](https://www.cs.cornell.edu/home/kleinber/link-pred.pdf)
- [SimRank (2002 paper)](https://web.stanford.edu/class/cs276/handouts/simrank.pdf)
