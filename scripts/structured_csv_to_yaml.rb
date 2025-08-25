#!/usr/bin/env ruby
require 'csv'
require 'yaml'
require 'optparse'


module CsvToStructuredHash

  def self.get_portion(csv, section_name)
    first_row = nil
    last_row = -1
    data_meta = {}

    puts "section_name #{section_name}"

    csv.each_with_index do |row, index|
      if first_row.nil? && is_start_of_portion?(row, section_name)
        # puts"found first"

        row[1].split(';').each do |opt|
          k, v = opt.split('=')
          data_meta[k.to_sym] = v
        end if row[1] && !row[1].empty?

        first_row = index+1
        next
      end

      if !first_row.nil? && is_row_empty?(row)
        # puts "found last"
        last_row = index
        break
      end
    end

    # puts "first #{first_row}  last #{last_row}"
    {
      first_row: first_row,
      last_row: last_row,
      rows: csv[first_row..last_row],
      meta: data_meta
    }
  end

  def self.is_start_of_portion?(row, section_name)
    return false if row.first.nil?
    row.first.strip.to_s == section_name.to_s
  end

  def self.is_row_empty?(row)
    row.map do |f|
      f.is_a?(String) ? f.strip : f
    end.all?(&:nil?)
  end

  def self.get_csv(csv_filename)
    content = File.read(csv_filename, encoding: "bom|utf-8")
    CSV.parse(content, liberal_parsing: true, encoding: "UTF-8")
  end

  def self.split_header_key_type(header_field)
    field_name = ""
    field_type = CAST_DEFAULT_TYPE

    # puts header_field
    arr = header_field.match(/\A(.*)\[(.*)\]\Z/)

    if arr.nil?
      field_name = header_field
    else
      field_name = arr[1]
      field_type = arr[2]
    end

    {
      name: field_name,
      type: field_type
    }
  end

  CAST_DEFAULT_TYPE = "string".freeze

  def self.cast_type(value, type_in_string)
    return if value.nil?
    type = type_in_string.downcase

    case type
    when "boolean"
      if value.downcase == "true"
        true
      elsif value.downcase == "false"
        false
      end
    when "integer"
      value.to_s.strip.to_i
    when "string"
      value.to_s.strip
    when /^array\{(.*)\}/
      val_type = Regexp.last_match[1] || CAST_DEFAULT_TYPE
      value.split(";").map do |v|
        # puts "cast type as #{v}, #{val_type.to_s}"
        cast_type(v, val_type.to_s)
      end
    else
      value.to_s
    end
  end

  def self.parse_metadata(rows)
    hash = {}

    rows.each_with_index do |row,index|
      # Skip all the empty rows
      next if is_row_empty?(row)

      name_type = split_header_key_type(row.first)
      key = name_type[:name]
      type = name_type[:type]

      value = cast_type(row[1], type)
      hash[key] = value
    end

    # puts "=============================METADATA================="
    # pp hash
    normalize_namespaces(hash)
  end

  def self.parse_data(rows, data_meta)
    header = []
    data_name = data_meta[:name]
    data_type = data_meta[:type] || "hash"
    data_key = data_meta[:key]

    base_structure = case data_type
    when "hash"
      {}
    when "array"
      []
    end

    rows.each_with_index do |row,index|
      # Assume the first column is always the key
      if index == 0
        # puts "row #{row}"
        header = row.map do |field|
          split_header_key_type(field) unless field.nil?
        end.compact

        if data_type == "hash" && data_key.nil?
          data_key = header.first
        end

        next
      end
      # puts "header #{header.inspect}"

      # Skip all the empty rows
      next if is_row_empty?(row)

      # Skip if no key value
      next if row[0].nil?

      header_names = header.inject([]) do |acc,v|
        acc << v[:name]
      end

      row_values = []
      header.each_with_index do |h, i|
        v = row[i]
        v = v.strip unless v.nil?
        row_values[i] = cast_type(v, h[:type])
      end

      k = row_values[0]
      d = Hash[header_names[0..-1].zip(row_values[0..-1])]
      #  .transform_keys { |k| k.to_sym }

      # Remove keys if they point to nil
      d.keys.each do |k|
        d.delete(k) if d[k].nil?
      end

      case data_type
      when "hash"
        unless base_structure[k].nil?
          puts "[WARNING] there is already data inside key [#{k}] -- maybe you should set type=array?"
        end
        base_structure[k] = normalize_namespaces(d)
      when "array"
        base_structure << normalize_namespaces(d)
      end
    end

    if data_name
      base_structure = {
        data_name => base_structure
      }
    end

    base_structure
  end

  def self.convert(csv_filename)
    raw_data = get_csv(csv_filename)

    metadata_section = get_portion(raw_data, "METADATA")
    data_section = get_portion(raw_data, "DATA")

    # puts '----------'
    # pp data_section[:rows]
    # puts '----------'

    {
      "metadata" => parse_metadata(metadata_section[:rows]),
      "data" => parse_data(data_section[:rows], data_section[:meta]),
      "meta" => data_section[:meta]
    }
  end

  # Structure all child hashes if the key is namespaced.
  # e.g. { "hello.me" => data } becomes
  #  { "hello" => { "me" => data } }
  #
  def self.normalize_namespaces(hash)
    new_hash = {}

    hash.each_pair do |k, v|
      # puts"k (#{k}) v (#{v})"
      key_components = k.to_s.split('.')

      level = new_hash
      last_component = key_components.pop
      key_components.each do |component|
        # puts"c (#{component})"
        level[component] ||= {}
        level = level[component]
      end

      level[last_component] = v
    end

    new_hash
  end
end


cli_options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ./structured_csv_to_yaml.rb [options]"
  opts.on('-p [PUBLICATION_ID]', '--pub_id [PUBLICATION_ID]', "Specify the publication ID") do |v|
    cli_options[:root_name] = v
  end
  opts.on("-c a.csv,b.csv,c.csv", "--csv a.csv,b.csv,c.csv", Array, "Specify one or more CSV files") do |list|
    cli_options[:csv] = list    
  end
  opts.on('-h', '--help', 'Display this help') do 
    puts opts
    exit
  end
end.parse!

if cli_options[:root_name]

  outfile_annexes = "annexes.yaml"
  default_type = "index"

  annexes_root = cli_options[:root_name]
  position_on = "????-??-??"

  csv_files = Array.new
  output_data = Hash.new
  output_metadata = Hash.new

  if cli_options[:csv]
    cli_options[:csv].each do|fname|
      puts "Argument must be a .csv file: #{fname}" unless fname =~ /\.csv$/
      csv_files.push(fname)
    end
    else
      puts "Please specify at least one .csv file"
  end

  first_csv = csv_files[0]

  output_data[annexes_root] = Hash.new
  output_data[annexes_root]["position_on"] = position_on
  output_data[annexes_root]["datasets"] = Hash.new

  csv_files.each do|fname|
    parsed_csv = CsvToStructuredHash.convert(fname)
    name_wo_ext = File.basename(fname, ".csv")

    output_data[annexes_root]["datasets"][name_wo_ext] = {
      "meta" => {
        "schema" => {
          "type" => "",
          "item" => Hash.new
        }
      }
    }

    if parsed_csv["metadata"]["title"]
      output_data[annexes_root]["datasets"][name_wo_ext]["meta"]["title"] = parsed_csv["metadata"]["title"]
    end

    if parsed_csv["metadata"]["locale"]
      fields = Array.new
      parsed_csv["metadata"]["locale"].each do |k, v|
        
        #text_type = "translated-text"
        text_type = "text"

        fields.push({
          "id" => k,
          "required" => true,
          "label" => v,
          "type" => text_type
        })
      end
    end

    if parsed_csv["metadata"][:type]
      output_data[annexes_root]["datasets"][name_wo_ext]["meta"]["schema"] = {"type" => parsed_csv["metadata"][:type]}
    else
      output_data[annexes_root]["datasets"][name_wo_ext]["meta"]["schema"] = {"type" => default_type}
    end

    if fields
      output_data[annexes_root]["datasets"][name_wo_ext]["meta"]["schema"]["item"] = fields
    end
    output_data[annexes_root]["datasets"][name_wo_ext]["contents"] = parsed_csv["data"]

  end

  IO.write(outfile_annexes, output_data.to_yaml)

else
  if ARGV.length == 0
    puts "Please specify the publication ID and CSV files: --pub_id [PUBLICATION_ID] --csv a.csv,b.csv,c.csv"
  else
    puts "Please specify the publication ID: --pub_id [PUBLICATION_ID]"
  end
end

# pp CsvToStructuredHash.convert(filename)
