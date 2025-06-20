# Ecto to Ash Converter

A powerful tool to automatically convert your existing Ecto schemas to Ash Framework resources with intelligent database introspection and validation migration.

## Overview

This tool helps you migrate from Ecto to Ash Framework by:

- 🔍 **Database Introspection**: Analyzes your PostgreSQL database to understand tables, constraints, indexes, and relationships
- 📄 **Ecto Schema Parsing**: Extracts validations, virtual fields, associations, and changesets from existing schemas
- 🏗️ **Intelligent Resource Generation**: Creates complete Ash resources with attributes, identities, relationships, and actions
- 📁 **Structure Preservation**: Maintains your existing folder organization
- ⚡ **Batch Processing**: Converts all schemas at once with a single command

## Features

### Database Introspection
- ✅ Primary keys (integer, UUID, composite)
- ✅ Foreign key relationships
- ✅ Unique constraints and indexes → Ash identities
- ✅ PostgreSQL enums with constraints
- ✅ Column types, nullability, defaults
- ✅ Timestamps detection
- ✅ Custom types (citext, jsonb, etc.)

### Ecto Schema Migration
- ✅ Virtual fields → Calculation placeholders
- ✅ Associations (belongs_to, has_many, has_one, many_to_many)
- ✅ Validations → Ash validation equivalents
- ✅ Changeset functions → Action structure suggestions
- ✅ Association naming preservation

### Generated Ash Resources Include
- 🎯 Proper attribute types with constraints
- 🔑 Primary key configuration (integer_primary_key/uuid_primary_key)
- 📅 Timestamps() macro when detected
- 🆔 Identities for all unique indexes
- 🔗 Relationship definitions
- ⚡ Default CRUD actions
- 📝 TODO comments for manual migration steps

## Installation

### Prerequisites

- Elixir project with Ecto and PostgreSQL
- [ripgrep](https://github.com/BurntSushi/ripgrep) installed
- Ash Framework dependencies (if not already added)

```bash
# Install ripgrep
# macOS
brew install ripgrep

# Ubuntu/Debian
apt install ripgrep

# Other platforms: https://github.com/BurntSushi/ripgrep#installation
```

### Setup

1. **Add the Mix task** to your project:
   ```bash
   # Copy the mix task file
   cp ash.gen.resource.ex lib/mix/tasks/
   ```

2. **Make the bash script executable**:
   ```bash
   chmod +x convert_ecto_schemas.sh
   ```

3. **Update your Mix dependencies** (if not already using Ash):
   ```elixir
   # mix.exs
   defp deps do
     [
       {:ash, "~> 3.0"},
       {:ash_postgres, "~> 2.0"},
       # ... your existing deps
     ]
   end
   ```

## Usage

### Single Schema Conversion

Convert a single Ecto schema with database introspection:

```bash
mix ash.gen.resource users lib/my_app/ash_resources --ecto-schema lib/my_app/accounts/user.ex
```

**Parameters:**
- `users` - Database table name
- `lib/my_app/ash_resources` - Output directory
- `--ecto-schema` - Path to existing Ecto schema (optional but recommended)

### Batch Conversion

Convert all Ecto schemas in your project:

```bash
./convert_ecto_schemas.sh lib/my_app/ash_resources
```

This will:
1. Find all `.ex` files in `lib/` containing `use Ecto.Schema`
2. Extract table names from each schema
3. Run the conversion for each one
4. Preserve your existing folder structure

## Example

### Input: Ecto Schema
```elixir
defmodule MyApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :account_type, Ecto.Enum, values: [:demo, :basic, :pro, :admin], default: :demo
    field :confirmed_at, :naive_datetime
    field :password, :string, virtual: true

    has_many :posts, MyApp.Blog.Post
    belongs_to :workspace, MyApp.Workspaces.Workspace

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password])
    |> validate_required([:username, :email])
    |> validate_format(:email, ~r/@/)
    |> validate_length(:username, min: 3, max: 20)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end
end
```

### Output: Ash Resource
```elixir
defmodule MyApp.Resources.Users do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo MyApp.Repo
  end

  attributes do
    integer_primary_key :id
    attribute :username, :string, allow_nil?: false
    attribute :email, :string, allow_nil?: false
    attribute :account_type, :atom, allow_nil?: true, 
              constraints: [one_of: [:demo, :basic, :pro, :admin]], default: :demo
    attribute :confirmed_at, :naive_datetime, allow_nil?: true

    # TODO: Convert these virtual fields to calculations:
    # calculate :password, :string, expr(...) # Define calculation logic

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
    identity :unique_username, [:username]
  end

  relationships do
    has_many :posts, MyApp.Resources.Posts do
      source_field :id
      destination_field :user_id
    end

    belongs_to :workspace, MyApp.Resources.Workspaces do
      source_field :workspace_id
      destination_field :id
    end
  end

  validations do
    validate present(:username)
    validate present(:email)
    validate match(:email, ~r/@/)
    validate string_length(:username, min: 3, max: 20)
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end
end
```

## Configuration

### Customizing the Mix Task

The Mix task accepts several options:

```bash
mix ash.gen.resource TABLE_NAME OUTPUT_DIR [OPTIONS]

Options:
  --ecto-schema PATH    Path to existing Ecto schema for enhanced conversion
```

### Supported PostgreSQL Types

The tool automatically maps PostgreSQL types to Ash types:

| PostgreSQL | Ash Type | Notes |
|------------|----------|-------|
| `varchar`, `text`, `citext` | `:string` | With length constraints |
| `integer`, `bigint`, `serial` | `:integer` | |
| `uuid` | `:uuid` | |
| `boolean` | `:boolean` | |
| `timestamp`, `timestamptz` | `:naive_datetime`, `:utc_datetime` | |
| `jsonb`, `json` | `:map` | |
| `numeric`, `decimal` | `:decimal` | With precision/scale |
| Custom enums | `:atom` | With `one_of` constraints |

## Migration Strategy

### Recommended Workflow

1. **Generate Ash resources** using this tool
2. **Review generated code** and add missing business logic
3. **Create Ash API module** to organize your resources
4. **Test resources** with existing data
5. **Gradually replace Ecto calls** with Ash actions
6. **Update tests** to use Ash instead of Ecto
7. **Remove Ecto schemas** once fully migrated

### Manual Migration Steps

After running the conversion, you'll need to:

- ✏️ **Convert virtual fields** to Ash calculations
- 🔄 **Migrate changeset logic** to Ash changes and validations  
- 🔗 **Verify relationships** work correctly with your data
- 🛡️ **Add policies** if using authorization
- 🧪 **Update tests** to use Ash actions
- ⚡ **Optimize actions** for your specific use cases

## Troubleshooting

### Common Issues

**"Table not found" errors:**
- Ensure your database is running and migrations are up to date
- Check that the table name matches exactly (case sensitive)

**"Mix task not found":**
- Verify the task file is in `lib/mix/tasks/ash.gen.resource.ex`
- Run `mix compile` to ensure the task is loaded

**"Could not extract table name":**
- Ensure your Ecto schema has either `schema "table_name"` or a clear module name
- Check the debug output for file parsing issues

**Relationships not generated:**
- Foreign key relationships require actual database foreign key constraints
- Use `--ecto-schema` flag to get association names from Ecto schema

### Getting Help

1. Check the debug output for specific error messages
2. Verify your database schema matches your Ecto schemas
3. Ensure all foreign key constraints exist in the database
4. Review the generated TODO comments for manual migration steps

## Contributing

Contributions welcome! This tool handles most common Ecto patterns, but there's always room for improvement:

- 🔧 Additional PostgreSQL type support
- 🎯 More Ecto validation patterns
- 🔗 Complex relationship detection
- 📝 Better error messages
- 🧪 Test coverage

## License

MIT License - see LICENSE file for details.

---

**⚡ Happy migrating from Ecto to Ash!** 

This tool gets you 80% of the way there automatically. The remaining 20% is where you add the Ash-specific magic that makes your API truly powerful.
