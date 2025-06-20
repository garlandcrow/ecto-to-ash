defmodule Mix.Tasks.Ash.Gen.Resource do
  use Mix.Task
  alias GMiner.Repo

  @shortdoc "Generates an Ash resource from an existing table"

  @moduledoc """
  Generates an Ash resource from a database table by introspecting schema, constraints, and foreign keys.
  Optionally uses an existing Ecto schema to extract validations, virtual fields, and other logic.

      mix ash.gen.resource users

      # With custom output directory:
      mix ash.gen.resource users lib/my_app/ash_resources

      # With existing Ecto schema for enhanced conversion:
      mix ash.gen.resource users lib/my_app/ash_resources --ecto-schema lib/my_app/accounts/user.ex

  Default output is: lib/my_app/resources/<table>.ex
  """

  @type_map %{
    "character varying" => :string,
    "varchar" => :string,
    "text" => :string,
    # Case-insensitive text
    "citext" => :string,
    "uuid" => :uuid,
    "integer" => :integer,
    "bigint" => :integer,
    "smallint" => :integer,
    "boolean" => :boolean,
    "timestamp with time zone" => :utc_datetime,
    "timestamp without time zone" => :naive_datetime,
    "timestamptz" => :utc_datetime,
    "date" => :date,
    "time" => :time,
    "jsonb" => :map,
    "json" => :map,
    "double precision" => :float,
    "real" => :float,
    "numeric" => :decimal,
    "decimal" => :decimal,
    "money" => :decimal,
    "bytea" => :binary,
    "inet" => :string,
    "cidr" => :string,
    "macaddr" => :string,
    "point" => :string,
    "box" => :string,
    "path" => :string,
    "polygon" => :string,
    "circle" => :string,
    "interval" => :string,
    "bit" => :string,
    "bit varying" => :string,
    "varbit" => :string,
    "serial" => :integer,
    "bigserial" => :integer,
    "smallserial" => :integer
  }

  def run(args) do
    {opts, [table_name | rest], _} =
      OptionParser.parse(args,
        strict: [ecto_schema: :string],
        aliases: [e: :ecto_schema]
      )

    Mix.Task.run("app.start")

    out_dir =
      case rest do
        [dir] -> Path.expand(dir)
        _ -> "lib/my_app/resources"
      end

    ecto_schema_path = opts[:ecto_schema]
    ecto_info = if ecto_schema_path, do: parse_ecto_schema(ecto_schema_path), else: %{}

    module_name = moduleize(table_name)
    file_name = Path.join(out_dir, "#{table_name}.ex")

    IO.puts("🔍 Introspecting `#{table_name}` → #{file_name}")
    if ecto_schema_path, do: IO.puts("📖 Using Ecto schema: #{ecto_schema_path}")

    File.mkdir_p!(out_dir)

    # Get all the data we need
    data = gather_table_data(table_name, ecto_info)

    # Generate the file content
    content = generate_resource_content(table_name, module_name, data)

    # Write the file
    File.write!(file_name, content)
    IO.puts("✅ File written: #{file_name}")

    # Print summary
    print_summary(data, ecto_info)
  end

  def run(_) do
    Mix.shell().error("Usage: mix ash.gen.resource <table_name> [output_directory] [--ecto-schema path/to/schema.ex]")
  end

  defp gather_table_data(table_name, ecto_info) do
    IO.puts("🔍 Starting introspection...")
    IO.puts("   Table: #{table_name}")

    # Enhanced column introspection with more details
    columns =
      Repo.query!(
        """
        SELECT 
          column_name, 
          data_type, 
          is_nullable,
          column_default,
          character_maximum_length,
          numeric_precision,
          numeric_scale,
          udt_name,
          ordinal_position
        FROM information_schema.columns
        WHERE table_name = $1
        ORDER BY ordinal_position
        """,
        [table_name]
      ).rows

    # Debug output for columns
    IO.puts("🔍 Found columns:")

    Enum.each(columns, fn [name, type, nullable, default | _] ->
      IO.puts("   • #{name}: #{type} (nullable: #{nullable}, default: #{inspect(default)})")
    end)

    # Get primary key information
    primary_keys =
      Repo.query!(
        """
        SELECT kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
        WHERE tc.table_name = $1 
          AND tc.constraint_type = 'PRIMARY KEY'
        ORDER BY kcu.ordinal_position
        """,
        [table_name]
      ).rows
      |> Enum.map(&hd/1)

    # Enhanced foreign key introspection
    fk_constraints =
      Repo.query!(
        """
        SELECT
          kcu.column_name,
          ccu.table_name AS foreign_table,
          ccu.column_name AS foreign_column,
          tc.constraint_name
        FROM
          information_schema.table_constraints AS tc
        JOIN
          information_schema.key_column_usage AS kcu
          ON tc.constraint_name = kcu.constraint_name
        JOIN
          information_schema.constraint_column_usage AS ccu
          ON ccu.constraint_name = tc.constraint_name
        WHERE
          tc.table_name = $1 AND tc.constraint_type = 'FOREIGN KEY'
        ORDER BY kcu.ordinal_position
        """,
        [table_name]
      ).rows

    # Enhanced unique constraint detection (both constraints and indexes)
    unique_constraints =
      Repo.query!(
        """
        -- Get unique constraints
        SELECT 
          tc.constraint_name as name,
          array_agg(kcu.column_name ORDER BY kcu.ordinal_position) as columns,
          'constraint' as type
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
        WHERE tc.table_name = $1 
          AND tc.constraint_type = 'UNIQUE'
        GROUP BY tc.constraint_name

        UNION

        -- Get unique indexes (including those not created as constraints)
        SELECT
          i.relname as name,
          array_agg(a.attname ORDER BY array_position(ix.indkey, a.attnum)) as columns,
          'index' as type
        FROM pg_class t
        JOIN pg_index ix ON t.oid = ix.indrelid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
        WHERE t.relname = $1
          AND ix.indisunique = true
          AND ix.indisprimary = false
        GROUP BY i.relname
        """,
        [table_name]
      ).rows

    # Debug output
    if unique_constraints != [] do
      IO.puts("🔍 Found unique constraints/indexes:")

      Enum.each(unique_constraints, fn [name, columns, type] ->
        IO.puts("   • #{type}: #{name} on #{inspect(columns)}")
      end)
    else
      IO.puts("⚠️  No unique constraints or indexes found")
    end

    # Check for enum types
    enum_types =
      Repo.query!(
        """
        SELECT 
          c.column_name,
          t.typname,
          array_agg(e.enumlabel ORDER BY e.enumsortorder) as enum_values
        FROM information_schema.columns c
        JOIN pg_type t ON c.udt_name = t.typname
        JOIN pg_enum e ON t.oid = e.enumtypid
        WHERE c.table_name = $1
        GROUP BY c.column_name, t.typname
        """,
        [table_name]
      ).rows

    enum_map =
      enum_types
      |> Enum.into(%{}, fn [col, _type, values] -> {col, values} end)

    # Get reverse relationships (has_many/has_one pointing to this table)
    reverse_fks =
      Repo.query!(
        """
        SELECT
          tc.table_name AS source_table,
          kcu.column_name AS source_column,
          ccu.column_name AS target_column
        FROM
          information_schema.table_constraints AS tc
        JOIN
          information_schema.key_column_usage AS kcu
          ON tc.constraint_name = kcu.constraint_name
        JOIN
          information_schema.constraint_column_usage AS ccu
          ON ccu.constraint_name = tc.constraint_name
        WHERE
          ccu.table_name = $1 AND tc.constraint_type = 'FOREIGN KEY'
        """,
        [table_name]
      ).rows

    %{
      columns: columns,
      primary_keys: primary_keys,
      fk_constraints: fk_constraints,
      unique_constraints: unique_constraints,
      enum_types: enum_types,
      enum_map: enum_map,
      reverse_fks: reverse_fks
    }
  end

  defp generate_resource_content(table_name, module_name, data) do
    lines = []

    # Module definition
    lines =
      lines ++
        [
          "defmodule #{module_name} do",
          "  use Ash.Resource,",
          "    data_layer: AshPostgres.DataLayer",
          "",
          "  postgres do",
          "    table \"#{table_name}\"",
          "    repo GMiner.Repo",
          "  end",
          ""
        ]

    # Attributes section
    lines = lines ++ generate_attributes_section(data)

    # Identities section
    lines = lines ++ generate_identities_section(data)

    # Relationships section
    lines = lines ++ generate_relationships_section(data)

    # Actions section
    lines = lines ++ generate_actions_section()

    # Close module
    lines = lines ++ ["end"]

    Enum.join(lines, "\n")
  end

  defp generate_attributes_section(data) do
    %{columns: columns, primary_keys: primary_keys, enum_map: enum_map} = data

    lines = ["  attributes do"]

    # Handle primary keys first
    {pk_lines, remaining_columns} =
      case primary_keys do
        ["id"] ->
          id_column = Enum.find(columns, fn [name | _] -> name == "id" end)

          case id_column do
            ["id", type, _, _default | _] when type in ["uuid"] ->
              {["    uuid_primary_key :id"], Enum.reject(columns, fn [name | _] -> name == "id" end)}

            ["id", type, _, _default | _] when type in ["integer", "bigint", "serial", "bigserial"] ->
              {["    integer_primary_key :id"], Enum.reject(columns, fn [name | _] -> name == "id" end)}

            _ ->
              {[], columns}
          end

        [] ->
          {[], columns}

        _multiple_pks ->
          IO.puts("⚠️  Warning: Composite primary key detected. Treating as regular attributes.")
          {[], columns}
      end

    lines = lines ++ pk_lines

    # Handle remaining attributes
    attr_lines =
      remaining_columns
      |> Enum.map(fn [name, type, is_nullable, default, max_length, precision, scale, udt_name | _] ->
        ash_type = determine_ash_type(type, udt_name, enum_map[name])
        nullable = is_nullable == "YES"

        # Handle timestamps specially - skip them for timestamps() macro
        if name in ["inserted_at", "updated_at"] and ash_type in [:naive_datetime, :utc_datetime] do
          # Will be handled by timestamps() macro
          nil
        else
          default_expr = format_default(default, ash_type, enum_map[name])
          constraints = build_constraints(ash_type, max_length, precision, scale, enum_map[name])

          base_attr = "    attribute :#{name}, :#{ash_type}, allow_nil?: #{nullable}"

          attr_with_constraints = if constraints != "", do: base_attr <> constraints, else: base_attr

          attr_with_default =
            if default_expr != "", do: attr_with_constraints <> default_expr, else: attr_with_constraints

          attr_with_default
        end
      end)
      |> Enum.reject(&is_nil/1)

    lines = lines ++ attr_lines

    # Add timestamps if we have both inserted_at and updated_at
    column_names = Enum.map(columns, fn [name | _] -> name end)
    has_inserted_at = "inserted_at" in column_names
    has_updated_at = "updated_at" in column_names

    lines =
      if has_inserted_at and has_updated_at do
        lines ++ ["", "    timestamps()"]
      else
        lines
      end

    lines ++ ["  end", ""]
  end

  defp generate_identities_section(data) do
    %{unique_constraints: unique_constraints} = data

    all_unique_columns =
      unique_constraints
      |> Enum.flat_map(fn [name, columns, type] ->
        case columns do
          [single_col] ->
            [{single_col, name, type}]

          multiple_cols ->
            IO.puts("⚠️  Warning: Multi-column unique #{type} #{name}: #{inspect(multiple_cols)}")
            # Still create identity for multi-column constraints
            [{Enum.join(multiple_cols, "_"), name, type}]
        end
      end)

    if all_unique_columns != [] do
      identity_lines =
        ["  identities do"] ++
          Enum.map(all_unique_columns, fn {identity_name, _constraint_name, _type} ->
            case String.contains?(identity_name, "_") do
              true ->
                # Multi-column identity
                columns = String.split(identity_name, "_")
                "    identity :unique_#{identity_name}, #{inspect(Enum.map(columns, &String.to_atom/1))}"

              false ->
                # Single column identity
                "    identity :unique_#{identity_name}, [:#{identity_name}]"
            end
          end) ++ ["  end", ""]

      identity_lines
    else
      []
    end
  end

  defp generate_relationships_section(_data) do
    # For now, just return empty - can be enhanced later
    []
  end

  defp generate_actions_section() do
    [
      "  actions do",
      "    defaults [:read, :create, :update, :destroy]",
      "  end",
      ""
    ]
  end

  defp print_summary(data, ecto_info) do
    %{
      columns: columns,
      primary_keys: primary_keys,
      fk_constraints: fk_constraints,
      unique_constraints: unique_constraints,
      enum_types: enum_types
    } = data

    IO.puts("\n📊 Summary:")
    IO.puts("   • #{length(columns)} columns")
    IO.puts("   • #{length(primary_keys)} primary key(s)")
    IO.puts("   • #{length(fk_constraints)} foreign key(s)")
    IO.puts("   • #{length(unique_constraints)} unique constraint(s)")
    IO.puts("   • #{length(enum_types)} enum type(s)")

    if ecto_info != %{} do
      virtual_count = count_virtual_fields(ecto_info)
      validation_count = count_validations(ecto_info)
      association_count = count_associations(ecto_info)
      IO.puts("   • #{virtual_count} virtual field(s) from Ecto")
      IO.puts("   • #{validation_count} validation(s) from Ecto")
      IO.puts("   • #{association_count} association(s) from Ecto")
    end
  end

  # Ecto schema parsing functions
  defp parse_ecto_schema(file_path) do
    if File.exists?(file_path) do
      try do
        content = File.read!(file_path)

        %{
          content: content,
          virtual_fields: extract_virtual_fields(content),
          associations: extract_associations(content),
          validations: extract_validations(content),
          changesets: extract_changesets(content)
        }
      rescue
        _ ->
          IO.puts("⚠️  Could not parse Ecto schema at #{file_path}")
          %{}
      end
    else
      IO.puts("⚠️  Ecto schema file not found: #{file_path}")
      %{}
    end
  end

  defp extract_virtual_fields(content) do
    Regex.scan(~r/field\s+:(\w+),\s+:\w+,\s+virtual:\s+true/, content)
    |> Enum.map(fn [_, field] -> field end)
  end

  defp extract_associations(content) do
    belongs_to =
      Regex.scan(~r/belongs_to\s+:(\w+),\s+(\w+)/, content)
      |> Enum.map(fn [_, name, module] -> {:belongs_to, name, module, nil} end)

    has_many =
      Regex.scan(~r/has_many\s+:(\w+),\s+(\w+)/, content)
      |> Enum.map(fn [_, name, module] -> {:has_many, name, module, nil} end)

    has_one =
      Regex.scan(~r/has_one\s+:(\w+),\s+(\w+)/, content)
      |> Enum.map(fn [_, name, module] -> {:has_one, name, module, nil} end)

    many_to_many =
      Regex.scan(~r/many_to_many\s+:(\w+),\s+(\w+),\s+join_through:\s+"?(\w+)"?/, content)
      |> Enum.map(fn [_, name, module, join_table] -> {:many_to_many, name, module, join_table} end)

    belongs_to ++ has_many ++ has_one ++ many_to_many
  end

  defp extract_validations(content) do
    # Extract common Ecto validations
    _validations = []

    # validate_required
    required =
      Regex.scan(~r/validate_required\(changeset,\s*\[([^\]]+)\]/, content)
      |> Enum.flat_map(fn [_, fields] ->
        String.split(fields, ",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, ":"))
      end)
      |> Enum.map(&{:required, &1})

    # validate_length
    length_validations =
      Regex.scan(~r/validate_length\(changeset,\s*:(\w+),\s*(.+?)\)/, content)
      |> Enum.map(fn [_, field, opts] -> {:length, field, opts} end)

    # validate_format
    format_validations =
      Regex.scan(~r/validate_format\(changeset,\s*:(\w+),\s*(.+?)\)/, content)
      |> Enum.map(fn [_, field, pattern] -> {:format, field, pattern} end)

    # validate_inclusion
    inclusion_validations =
      Regex.scan(~r/validate_inclusion\(changeset,\s*:(\w+),\s*(.+?)\)/, content)
      |> Enum.map(fn [_, field, values] -> {:inclusion, field, values} end)

    # validate_number
    number_validations =
      Regex.scan(~r/validate_number\(changeset,\s*:(\w+),\s*(.+?)\)/, content)
      |> Enum.map(fn [_, field, opts] -> {:number, field, opts} end)

    required ++ length_validations ++ format_validations ++ inclusion_validations ++ number_validations
  end

  defp extract_changesets(content) do
    # Extract changeset function names and their logic
    changesets =
      Regex.scan(~r/def\s+(\w*changeset)\([^)]+\)\s+do(.+?)end/s, content)
      |> Enum.map(fn [_, name, body] -> {name, String.trim(body)} end)

    IO.puts("🔍 Found changesets: #{inspect(Enum.map(changesets, fn {name, _} -> name end))}")
    changesets
  end

  defp determine_ash_type(pg_type, udt_name, enum_values) do
    cond do
      enum_values != nil ->
        :atom

      Map.has_key?(@type_map, pg_type) ->
        @type_map[pg_type]

      Map.has_key?(@type_map, udt_name) ->
        @type_map[udt_name]

      # Handle citext specifically
      udt_name == "citext" ->
        :string

      pg_type == "USER-DEFINED" and udt_name == "citext" ->
        :string

      true ->
        IO.puts("⚠️  Unknown type: #{pg_type} (#{udt_name}), defaulting to :string")
        :string
    end
  end

  defp format_default(default, ash_type, enum_values) do
    cond do
      is_nil(default) ->
        ""

      is_binary(default) and String.starts_with?(default, "nextval(") ->
        ""

      is_binary(default) and String.contains?(default, "now()") ->
        case ash_type do
          :utc_datetime -> ", default: &DateTime.utc_now/0"
          :naive_datetime -> ", default: &NaiveDateTime.utc_now/0"
          _ -> ""
        end

      enum_values != nil ->
        clean_default = String.trim(default, "'")

        if clean_default in enum_values do
          ", default: :#{clean_default}"
        else
          ""
        end

      ash_type == :string and is_binary(default) ->
        clean_default = default |> String.trim("'") |> String.replace("''", "'")
        ", default: #{inspect(clean_default)}"

      ash_type == :boolean ->
        case String.downcase(default) do
          "true" -> ", default: true"
          "false" -> ", default: false"
          _ -> ""
        end

      ash_type in [:integer, :float, :decimal] ->
        case Integer.parse(default) do
          {int_val, ""} ->
            ", default: #{int_val}"

          _ ->
            case Float.parse(default) do
              {float_val, ""} -> ", default: #{float_val}"
              _ -> ""
            end
        end

      true ->
        ""
    end
  end

  defp build_constraints(ash_type, max_length, precision, scale, enum_values) do
    constraints = []

    constraints =
      if enum_values != nil do
        enum_atoms = Enum.map(enum_values, &String.to_atom/1)
        constraints ++ ["one_of: #{inspect(enum_atoms)}"]
      else
        constraints
      end

    constraints =
      if ash_type == :string and max_length do
        constraints ++ ["max_length: #{max_length}"]
      else
        constraints
      end

    constraints =
      if ash_type == :decimal and precision do
        scale_part = if scale, do: ", scale: #{scale}", else: ""
        constraints ++ ["precision: #{precision}#{scale_part}"]
      else
        constraints
      end

    if constraints == [] do
      ""
    else
      ", constraints: [" <> Enum.join(constraints, ", ") <> "]"
    end
  end

  defp count_virtual_fields(ecto_info), do: length(Map.get(ecto_info, :virtual_fields, []))
  defp count_validations(ecto_info), do: length(Map.get(ecto_info, :validations, []))
  defp count_associations(ecto_info), do: length(Map.get(ecto_info, :associations, []))

  defp moduleize(table) do
    "GMiner.Resources." <>
      (table
       |> String.split("_")
       |> Enum.map(&String.capitalize/1)
       |> Enum.join())
  end
end

