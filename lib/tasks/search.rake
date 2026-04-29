# typed: false

namespace :search do
  desc "Rebuild the entire search index from scratch"
  task reindex: :environment do
    puts "Rebuilding search index..."
    count = 0

    SearchIndexer::INDEXABLE_TYPES.each do |klass|
      klass.unscoped_for_system_job.find_each do |item|
        SearchIndexer.reindex(item)
        count += 1
        print "." if (count % 100).zero?
      end
    end

    puts "\nReindexed #{count} items."
  end

  desc "Reindex search entries for a specific item type (e.g. rake search:reindex_type[Note])"
  task :reindex_type, [:type] => :environment do |_t, args|
    type = args[:type]
    klass = type.constantize
    unless SearchIndexer::INDEXABLE_TYPES.include?(klass)
      puts "Error: #{type} is not an indexable type. Valid: #{SearchIndexer::INDEXABLE_TYPES.map(&:name).join(', ')}"
      exit 1
    end

    puts "Reindexing all #{type} records..."
    count = 0
    klass.unscoped_for_system_job.find_each do |item|
      SearchIndexer.reindex(item)
      count += 1
      print "." if (count % 100).zero?
    end

    puts "\nReindexed #{count} #{type} records."
  end
end
