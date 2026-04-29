# typed: true

class NoteTableValidator
  extend T::Sig

  MAX_COLUMNS = 20
  MAX_ROWS = 500
  MAX_CELL_VALUE_LENGTH = 1_000
  MAX_COLUMN_NAME_LENGTH = 50
  MAX_TABLE_DATA_BYTES = 2_000_000
  VALID_COLUMN_TYPES = %w[text number boolean date].freeze
  COLUMN_NAME_FORMAT = /\A[a-zA-Z0-9 _]+\z/

  sig { params(table_data: T.untyped, errors: ActiveModel::Errors).void }
  def self.validate(table_data, errors)
    unless table_data.is_a?(Hash)
      errors.add(:table_data, "must be present for table notes")
      return
    end

    columns = table_data["columns"] || []
    rows = table_data["rows"] || []

    validator = new(columns, rows, table_data)
    validator.validate_all(errors)
  end

  sig { params(columns: T::Array[T.untyped], rows: T::Array[T.untyped], table_data: T::Hash[String, T.untyped]).void }
  def initialize(columns, rows, table_data)
    @columns = columns
    @rows = rows
    @table_data = table_data
  end

  sig { params(errors: ActiveModel::Errors).void }
  def validate_all(errors)
    validate_columns(errors)
    validate_rows(errors)
    validate_total_size(errors)
  end

  private

  sig { params(errors: ActiveModel::Errors).void }
  def validate_columns(errors)
    if @columns.length > MAX_COLUMNS
      errors.add(:table_data, "cannot have more than #{MAX_COLUMNS} columns")
    end

    col_names = @columns.map { |c| c["name"] }
    if col_names.uniq.length != col_names.length
      errors.add(:table_data, "column names must be unique")
    end

    @columns.each do |col|
      name = col["name"].to_s
      if name.blank?
        errors.add(:table_data, "column names cannot be blank")
      elsif name.length > MAX_COLUMN_NAME_LENGTH
        errors.add(:table_data, "column name '#{name.truncate(20)}' exceeds #{MAX_COLUMN_NAME_LENGTH} characters")
      elsif !name.match?(COLUMN_NAME_FORMAT)
        errors.add(:table_data, "column name '#{name.truncate(20)}' contains invalid characters (alphanumeric, spaces, underscores only)")
      elsif name.start_with?("_")
        errors.add(:table_data, "column names cannot start with underscore (reserved for metadata)")
      end

      unless VALID_COLUMN_TYPES.include?(col["type"])
        errors.add(:table_data, "invalid column type '#{col['type']}' (valid: #{VALID_COLUMN_TYPES.join(', ')})")
      end
    end
  end

  sig { params(errors: ActiveModel::Errors).void }
  def validate_rows(errors)
    if @rows.length > MAX_ROWS
      errors.add(:table_data, "cannot have more than #{MAX_ROWS} rows")
    end

    col_names = @columns.map { |c| c["name"] }
    @rows.each do |row|
      col_names.each do |col_name|
        value = row[col_name]
        if value.present? && value.to_s.length > MAX_CELL_VALUE_LENGTH
          errors.add(:table_data, "cell value in column '#{col_name}' exceeds #{MAX_CELL_VALUE_LENGTH} characters")
          return
        end
      end
    end
  end

  sig { params(errors: ActiveModel::Errors).void }
  def validate_total_size(errors)
    if @table_data.to_json.bytesize > MAX_TABLE_DATA_BYTES
      errors.add(:table_data, "total table size exceeds #{MAX_TABLE_DATA_BYTES / 1_000_000}MB limit")
    end
  end
end
