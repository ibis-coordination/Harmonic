# typed: true

class NoteTableService
  extend T::Sig

  sig { params(note: Note).void }
  def initialize(note)
    @note = note
    raise "Not a table note" unless @note.is_table?
  end

  # Accessors

  sig { returns(T.nilable(String)) }
  def description
    @note.table_data&.dig("description")
  end

  sig { returns(T::Array[T::Hash[String, String]]) }
  def columns
    @note.table_data&.dig("columns") || []
  end

  sig { returns(T::Array[T::Hash[String, T.untyped]]) }
  def rows
    @note.table_data&.dig("rows") || []
  end

  sig { returns(T::Array[String]) }
  def column_names
    columns.filter_map { |c| c["name"] }
  end

  # Schema mutations

  sig { params(cols: T::Array[T::Hash[String, String]]).void }
  def define_columns!(cols)
    raise "Cannot replace columns when rows exist" if rows.any? && columns.any?

    new_data = mutable_data
    new_data["columns"] = cols
    apply_and_save!(new_data)
  end

  sig { params(name: String, type: String).void }
  def add_column!(name, type)
    new_data = mutable_data
    new_data["columns"] << { "name" => name, "type" => type }
    apply_and_save!(new_data)
  end

  sig { params(name: String).void }
  def remove_column!(name)
    raise "Column '#{name}' not found" unless column_names.include?(name)

    new_data = mutable_data
    new_data["columns"] = new_data["columns"].reject { |c| c["name"] == name }
    new_data["rows"] = new_data["rows"].map { |row| row.except(name) }
    apply_and_save!(new_data)
  end

  # Row mutations

  sig { params(values: T::Hash[String, T.untyped], created_by: User).returns(T::Hash[String, T.untyped]) }
  def add_row!(values, created_by:)
    row = {
      "_id" => SecureRandom.hex(4),
      "_created_by" => created_by.id,
      "_created_at" => Time.current.iso8601,
    }
    column_names.each do |col_name|
      row[col_name] = values[col_name]&.to_s
    end

    new_data = mutable_data
    new_data["rows"] << row
    apply_and_save!(new_data)
    row
  end

  sig { params(row_id: String, values: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def update_row!(row_id, values)
    new_data = mutable_data
    row_index = new_data["rows"].index { |r| r["_id"] == row_id }
    raise "Row '#{row_id}' not found" unless row_index

    row = new_data["rows"][row_index] = new_data["rows"][row_index].dup
    values.each do |col_name, value|
      next unless column_names.include?(col_name)
      row[col_name] = value&.to_s
    end

    apply_and_save!(new_data)
    row
  end

  sig { params(row_id: String).void }
  def delete_row!(row_id)
    new_data = mutable_data
    original_count = new_data["rows"].length
    new_data["rows"] = new_data["rows"].reject { |r| r["_id"] == row_id }
    raise "Row '#{row_id}' not found" if new_data["rows"].length == original_count

    apply_and_save!(new_data)
  end

  sig { params(description_text: T.nilable(String)).void }
  def update_description!(description_text)
    new_data = mutable_data
    new_data["description"] = description_text
    apply_and_save!(new_data)
  end

  # Batch operations — multiple changes, one save, one event

  sig { params(block: T.proc.params(arg0: NoteTableService).void).void }
  def batch_update!(&block)
    @batch_mode = true
    block.call(self)
    save!
  ensure
    @batch_mode = false
  end

  # Query

  sig do
    params(
      where: T::Hash[String, T.untyped],
      order_by: T.nilable(String),
      order: String,
      limit: Integer,
      offset: Integer,
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def query_rows(where: {}, order_by: nil, order: "asc", limit: 20, offset: 0)
    result = rows

    where.each do |col_name, value|
      result = result.select { |r| r[col_name.to_s] == value.to_s }
    end

    total = result.length

    if order_by.present? && column_names.include?(order_by)
      result = result.sort_by { |r| r[order_by].to_s }
      result = result.reverse if order == "desc"
    end

    result = result.drop(offset).take(limit)

    { rows: result, total: total }
  end

  # Aggregation

  sig do
    params(
      operation: String,
      column: T.nilable(String),
      where: T::Hash[String, T.untyped],
    ).returns(T.untyped)
  end
  def summarize(operation:, column: nil, where: {})
    result = query_rows(where: where, limit: NoteTableValidator::MAX_ROWS)
    matched_rows = result[:rows]

    case operation
    when "count"
      matched_rows.length
    when "sum"
      raise "column is required for sum" unless column
      matched_rows.sum { |r| r[column].to_f }
    when "average"
      raise "column is required for average" unless column
      return 0.0 if matched_rows.empty?
      matched_rows.sum { |r| r[column].to_f } / matched_rows.length
    when "min"
      raise "column is required for min" unless column
      matched_rows.map { |r| r[column].to_s }.min
    when "max"
      raise "column is required for max" unless column
      matched_rows.map { |r| r[column].to_s }.max
    else
      raise "Unknown operation '#{operation}'. Valid: count, sum, average, min, max"
    end
  end

  private

  # Returns a mutable copy of table_data with defaults for columns and rows.
  # Dups the arrays so mutations don't affect @note.table_data until apply_and_save!.
  sig { returns(T::Hash[String, T.untyped]) }
  def mutable_data
    d = (@note.table_data || {}).dup
    d["columns"] = (d["columns"] || []).dup
    d["rows"] = (d["rows"] || []).dup
    d
  end

  sig { params(new_data: T::Hash[String, T.untyped]).void }
  def apply_and_save!(new_data)
    @note.table_data = new_data
    @note.text = NoteTableFormatter.to_markdown(new_data)
    @note.updated_by = @note.updated_by || @note.created_by
    save! unless @batch_mode
  end

  sig { void }
  def save!
    @note.save!
  end
end
