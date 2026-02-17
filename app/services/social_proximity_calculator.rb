# typed: true

# Computes social proximity between users using Personalized PageRank (PPR)
# with Adamic-Adar weighting. This creates a measure of connection
# that naturally favors smaller, more selective groups over large ones.
#
# Philosophy: Unlike traditional social media algorithms that amplify popular content
# (reinforcing feedback loop), this algorithm dampens popularity's influence
# (balancing feedback loop). As content gets more attention, its weight decreases.
class SocialProximityCalculator
  extend T::Sig

  WALK_COUNT = 1000        # Number of random walks
  WALK_LENGTH = 6          # Steps per walk (3 user→group→user hops)
  TELEPORT_PROB = 0.15     # Probability of returning to source

  sig { params(source_user: User, tenant_id: String).void }
  def initialize(source_user, tenant_id:)
    @source = source_user
    @tenant_id = tenant_id
    @landing_counts = T.let(Hash.new(0), T::Hash[String, Integer])
    # Structure: { user_id => [group_keys] }
    @user_groups = T.let({}, T::Hash[String, T::Array[String]])
    # Structure: { group_key => [user_ids] }
    @group_members = T.let({}, T::Hash[String, T::Array[String]])
    # Structure: { group_key => member_count }
    @group_sizes = T.let({}, T::Hash[String, Integer])
  end

  sig { returns(T::Hash[String, Float]) }
  def compute
    preload_graph_data
    WALK_COUNT.times { random_walk }
    normalize_results
  end

  private

  sig { void }
  def preload_graph_data
    load_collective_memberships
    load_note_reader_groups
    load_decision_voter_groups
    load_commitment_joiner_groups
    load_heartbeat_groups
  end

  sig { void }
  def load_collective_memberships
    # Get source user's collectives (1-hop)
    source_collective_ids = CollectiveMember
      .where(tenant_id: @tenant_id, user_id: @source.id, archived_at: nil)
      .pluck(:collective_id)

    return if source_collective_ids.empty?

    # Get all users in those collectives (1-hop users)
    one_hop_user_ids = CollectiveMember
      .where(tenant_id: @tenant_id, collective_id: source_collective_ids, archived_at: nil)
      .distinct.pluck(:user_id)

    # Get all collectives those users belong to (2-hop collectives)
    two_hop_collective_ids = CollectiveMember
      .where(tenant_id: @tenant_id, user_id: one_hop_user_ids, archived_at: nil)
      .distinct.pluck(:collective_id)

    # Now get ALL members of all reachable collectives (for complete random walks)
    CollectiveMember
      .where(tenant_id: @tenant_id, collective_id: two_hop_collective_ids, archived_at: nil)
      .pluck(:user_id, :collective_id)
      .each do |user_id, collective_id|
        add_user_to_group(user_id, "collective:#{collective_id}")
      end

    # Calculate sizes for collective groups
    @group_members.each do |key, members|
      @group_sizes[key] = members.uniq.size if key.start_with?("collective:")
    end
  end

  sig { void }
  def load_note_reader_groups
    # Get notes the source user has read
    source_note_ids = NoteHistoryEvent
      .where(tenant_id: @tenant_id, user_id: @source.id, event_type: "read_confirmation")
      .pluck(:note_id)

    return if source_note_ids.empty?

    # Get all readers of those notes
    NoteHistoryEvent
      .where(tenant_id: @tenant_id, note_id: source_note_ids, event_type: "read_confirmation")
      .pluck(:user_id, :note_id)
      .each do |user_id, note_id|
        add_user_to_group(user_id, "note:#{note_id}")
      end

    # Calculate sizes for note groups
    @group_members.each do |key, members|
      @group_sizes[key] = members.uniq.size if key.start_with?("note:")
    end
  end

  sig { void }
  def load_decision_voter_groups
    # Get decisions the source user has voted on
    # We need to find votes where the decision_participant has our user_id
    source_decision_ids = Vote
      .joins(:decision_participant)
      .where(tenant_id: @tenant_id, decision_participants: { user_id: @source.id })
      .distinct
      .pluck(:decision_id)

    return if source_decision_ids.empty?

    # Get all voters on those decisions
    Vote
      .joins(:decision_participant)
      .where(tenant_id: @tenant_id, decision_id: source_decision_ids)
      .where.not(decision_participants: { user_id: nil })
      .distinct
      .pluck("decision_participants.user_id", :decision_id)
      .each do |user_id, decision_id|
        add_user_to_group(user_id, "decision:#{decision_id}")
      end

    # Calculate sizes for decision groups
    @group_members.each do |key, members|
      @group_sizes[key] = members.uniq.size if key.start_with?("decision:")
    end
  end

  sig { void }
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
        add_user_to_group(user_id, "commitment:#{commitment_id}")
      end

    # Calculate sizes for commitment groups
    @group_members.each do |key, members|
      @group_sizes[key] = members.uniq.size if key.start_with?("commitment:")
    end
  end

  sig { void }
  def load_heartbeat_groups
    # Get collectives where source user has heartbeats
    source_collective_ids = Heartbeat
      .where(tenant_id: @tenant_id, user_id: @source.id)
      .distinct
      .pluck(:collective_id)

    return if source_collective_ids.empty?

    # For each collective, group heartbeats by the current cycle
    source_collective_ids.each do |collective_id|
      collective = Collective.find_by(id: collective_id)
      next unless collective

      # Get the current cycle for this collective
      cycle = Cycle.new_from_collective(collective)
      cycle_key = cycle.name # e.g., "today", "this-week"

      # Get all users with heartbeats in this collective during this cycle
      user_ids = T.unsafe(Heartbeat)
        .where(tenant_id: @tenant_id, collective_id: collective_id)
        .where_in_cycle(cycle)
        .distinct
        .pluck(:user_id)

      next if user_ids.size < 2 # Skip if only the source user

      group_key = "heartbeat:#{collective_id}:#{cycle_key}"
      user_ids.each do |user_id|
        add_user_to_group(user_id, group_key)
      end
      @group_sizes[group_key] = user_ids.size
    end
  end

  sig { void }
  def random_walk
    current_user_id = T.let(@source.id, String)

    (WALK_LENGTH / 2).times do
      # Teleport back to source with probability TELEPORT_PROB
      if rand < TELEPORT_PROB
        current_user_id = @source.id
        next
      end

      # User → Group (weighted by selectivity)
      group_keys = user_groups_for(current_user_id)
      return if group_keys.empty?

      group_key = weighted_sample(group_keys)

      # Group → User (uniform random)
      member_ids = group_members_for(group_key)
      next if member_ids.empty?

      sampled_id = T.cast(member_ids.sample, T.nilable(String))
      next if sampled_id.nil?

      current_user_id = sampled_id

      increment_landing_count(current_user_id) if current_user_id != @source.id
    end
  end

  sig { params(group_keys: T::Array[String]).returns(String) }
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
      cumulative += T.must(weight)
      return T.must(key) if r <= cumulative
    end

    T.must(group_keys.last)
  end

  sig { returns(T::Hash[String, Float]) }
  def normalize_results
    total = @landing_counts.values.sum.to_f
    return {} if total.zero?

    @landing_counts
      .transform_values { |count| count / total }
      .sort_by { |_id, score| -score }
      .to_h
  end

  # Helper to get or create a user's group list
  sig { params(user_id: String).returns(T::Array[String]) }
  def user_groups_for(user_id)
    @user_groups[user_id] ||= []
  end

  # Helper to get or create a group's member list
  sig { params(group_key: String).returns(T::Array[String]) }
  def group_members_for(group_key)
    @group_members[group_key] ||= []
  end

  # Helper to add a user to a group
  sig { params(user_id: String, group_key: String).void }
  def add_user_to_group(user_id, group_key)
    user_groups_for(user_id) << group_key
    group_members_for(group_key) << user_id
  end

  # Helper to increment landing count (handles nil default)
  sig { params(user_id: String).void }
  def increment_landing_count(user_id)
    @landing_counts[user_id] = (@landing_counts[user_id] || 0) + 1
  end
end
