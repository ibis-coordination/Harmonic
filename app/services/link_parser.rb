class LinkParser
  def self.parse(text, subdomain: nil, studio_handle: nil)
    models = { 'n' => Note, 'c' => Commitment, 'd' => Decision, 'r' => RepresentationSession }
    domain = "#{subdomain}.#{ENV['HOSTNAME']}" + (studio_handle ? "/studios/#{studio_handle}" : '')
    prefixes = models.keys.join
    pattern = Regexp.new("https://#{domain}/([#{prefixes}])/([0-9a-f-]+)")
    memo = {}
    text.gsub(pattern) do |match|
      prefix = $1
      id = $2
      model = models[prefix]
      column_name = id.length == 8 ? :truncated_id : :id
      record = model.find_by(column_name => id)
      if record && !memo[record.id]
        memo[record.id] = true
        yield record
      end
    end
  end

  def self.parse_path(path)
    models = { 'n' => Note, 'c' => Commitment, 'd' => Decision, 'r' => RepresentationSession }
    path_pieces = path.split('/')
    prefix = path_pieces[-2]
    id = path_pieces[-1]
    studio_handle = path_pieces[-3]
    studio_ids = Studio.where(handle: studio_handle).pluck(:id)
    model = models[prefix]
    column_name = id.length == 8 ? :truncated_id : :id
    record = model.find_by(column_name => id, studio_id: studio_ids)
  end

  def initialize(from_record: nil, subdomain: nil, studio_handle: nil)
    @from_record = from_record
    @subdomain = subdomain
    @studio_handle = studio_handle
    if @from_record.nil? && (@subdomain.nil? || @studio_handle.nil?)
      raise ArgumentError, "Must pass in either from_record or subdomain + studio_handle"
    elsif @from_record && @subdomain
      raise ArgumentError, "Cannot pass in both from_record and subdomain/studio_handle"
    end
  end

  def parse(text = nil)
    if @from_record
      if text
        raise ArgumentError, "Cannot pass in text with from_record"
      end
      text = @from_record.class == Note ? @from_record.text : @from_record.description
      subdomain = @from_record.tenant.subdomain
      studio_handle = @from_record.studio.handle
      self.class.parse(text, subdomain: subdomain, studio_handle: studio_handle) do |to_record|
        yield to_record
      end
    elsif @subdomain && @studio_handle
      if text.nil?
        raise ArgumentError, "Cannot pass in subdomain without text"
      end
      self.class.parse(text, subdomain: @subdomain, studio_handle: @studio_handle) do |to_record|
        yield to_record
      end
    else
      raise ArgumentError, "Cannot parse without text or from_record"
    end
  end

  def parse_and_create_link_records!
    unless @from_record
      raise ArgumentError, "Cannot create link records without a from_record"
    end
    existing_links = Link.where(from_linkable: @from_record)
    # Create hash of existing links by to_record_id
    existing_links_by_to_linkable_id = existing_links.index_by(&:to_linkable_id)
    self.parse do |to_record|
      existing_link = existing_links_by_to_linkable_id[to_record.id]
      if existing_link
        existing_links_by_to_linkable_id.delete(to_record.id)
      else
        Link.create!(from_linkable: @from_record, to_linkable: to_record)
      end
    end
    # Links that are no longer in the text should be destroyed
    existing_links_by_to_linkable_id.values.each(&:destroy)
  end
end