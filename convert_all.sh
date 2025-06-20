#!/bin/bash

# Script to convert all Ecto schemas to Ash resources
# Usage: ./convert_ecto_schemas.sh <output_directory>
#
# This script:
# 1. Finds all .ex files containing "use Ecto.Schema"
# 2. Extracts the table name from each schema
# 3. Runs the ash.gen.resource Mix task for each one
# 4. Preserves the original folder structure in the output directory

set -e # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if output directory is provided
if [ $# -eq 0 ]; then
  echo -e "${RED}Error: Please provide an output directory${NC}"
  echo "Usage: $0 <output_directory>"
  echo "Example: $0 lib/my_app/ash_resources"
  exit 1
fi

OUTPUT_DIR="$1"

# Function to extract table name from Ecto schema
extract_table_name() {
  local file="$1"

  # Look for schema "table_name" declaration with more precise regex
  local table_name=""

  # First try to find explicit schema "table_name" declaration
  # Use a more specific pattern that only captures the table name
  table_name=$(grep -oE 'schema\s+"[^"]+' "$file" | head -1 | grep -oE '"[^"]+' | tr -d '"')

  if [ -n "$table_name" ]; then
    echo "$table_name"
    return 0
  fi

  # If no explicit table name, derive from module name
  # Extract the last part of the module name and pluralize it
  local module_name=$(grep -oE 'defmodule\s+[A-Za-z0-9_.]+' "$file" | head -1 | grep -oE '[A-Za-z0-9_.]+$')
  if [ -n "$module_name" ]; then
    # Get the last part after the last dot and convert to snake_case plural
    local base_name=$(echo "$module_name" | sed 's/.*\.//' | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//')
    # Simple pluralization (add 's' if doesn't end in 's')
    if [[ "$base_name" != *s ]]; then
      table_name="${base_name}s"
    else
      table_name="$base_name"
    fi
    echo "$table_name"
    return 0
  fi

  return 1
}

# Function to convert relative path to output path preserving structure
get_output_path() {
  local input_file="$1"
  local output_base="$2"

  # Get the directory of the input file relative to current directory
  local relative_dir=$(dirname "$input_file")

  # Create the corresponding directory in output
  local output_path="$output_base/$relative_dir"
  echo "$output_path"
}

# Function to check if ripgrep is available
check_ripgrep() {
  if ! command -v rg &>/dev/null; then
    echo -e "${RED}Error: ripgrep (rg) is not installed${NC}"
    echo "Please install ripgrep:"
    echo "  macOS: brew install ripgrep"
    echo "  Ubuntu/Debian: apt install ripgrep"
    echo "  Other: https://github.com/BurntSushi/ripgrep#installation"
    exit 1
  fi
}

# Function to check if Mix task exists
check_mix_task() {
  if ! mix help ash.gen.resource &>/dev/null; then
    echo -e "${RED}Error: Mix task 'ash.gen.resource' not found${NC}"
    echo "Make sure you have the task file in lib/mix/tasks/ash.gen.resource.ex"
    exit 1
  fi
}

# Main function
main() {
  echo -e "${BLUE}🔍 Converting Ecto schemas to Ash resources${NC}"
  echo -e "${BLUE}Output directory: ${OUTPUT_DIR}${NC}"
  echo ""

  # Check if ripgrep and Mix task exist
  check_ripgrep
  check_mix_task

  # Create output directory if it doesn't exist
  mkdir -p "$OUTPUT_DIR"

  # Find all .ex files containing "use Ecto.Schema" using ripgrep
  echo -e "${YELLOW}🔍 Finding Ecto schema files in lib/ folder...${NC}"

  local schema_files=()

  # Debug: First show what ripgrep finds
  echo -e "${YELLOW}Debug: Files found by ripgrep:${NC}"
  rg -l --type=elixir --glob='*.ex' 'use Ecto\.Schema' lib/ | sed 's/^/  • /'
  echo ""

  # Only search the lib/ folder for Ecto schemas and filter out any deps paths
  while IFS= read -r file; do
    # Extra safety: skip any file that contains 'deps' in the path
    if [[ "$file" != *"deps"* ]]; then
      schema_files+=("$file")
    else
      echo -e "${YELLOW}   Skipping deps file: $file${NC}"
    fi
  done < <(rg -l --type=elixir --glob='*.ex' 'use Ecto\.Schema' lib/)

  if [ ${#schema_files[@]} -eq 0 ]; then
    echo -e "${YELLOW}No Ecto schema files found in lib/ folder${NC}"
    echo "Searched for files containing 'use Ecto.Schema' in lib/*.ex files"
    exit 0
  fi

  echo -e "${GREEN}Found ${#schema_files[@]} Ecto schema file(s):${NC}"
  printf '%s\n' "${schema_files[@]}" | sed 's/^/  • /'
  echo ""

  # Process each schema file
  local success_count=0
  local error_count=0
  local errors=()

  for file in "${schema_files[@]}"; do
    echo -e "${BLUE}📝 Processing: $file${NC}"

    # Extract table name
    local table_name=$(extract_table_name "$file")

    if [ -z "$table_name" ]; then
      echo -e "${RED}   ❌ Could not extract table name from $file${NC}"
      echo -e "${YELLOW}   Debug: Here are the first few lines of the file:${NC}"
      head -10 "$file" | sed 's/^/     /'
      errors+=("$file: Could not extract table name")
      ((error_count++))
      continue
    fi

    echo -e "   📋 Table name: '$table_name'"

    # Validate table name doesn't contain weird characters
    if [[ "$table_name" =~ [^a-zA-Z0-9_] ]]; then
      echo -e "${RED}   ❌ Invalid table name extracted: '$table_name'${NC}"
      echo -e "${YELLOW}   Debug: Here are the schema lines from the file:${NC}"
      grep -n "schema\|defmodule" "$file" | sed 's/^/     /'
      errors+=("$file: Invalid table name extracted")
      ((error_count++))
      continue
    fi

    # Get output path preserving directory structure
    local output_path=$(get_output_path "$file" "$OUTPUT_DIR")

    echo -e "   📁 Output path: $output_path"

    # Create output directory
    mkdir -p "$output_path"

    # Convert to absolute path for the input file
    local abs_file=$(realpath "$file")

    # Run the Mix task
    echo -e "   🔄 Running conversion..."

    if mix ash.gen.resource "$table_name" "$output_path" --ecto-schema "$abs_file"; then
      echo -e "   ${GREEN}✅ Successfully converted $file${NC}"
      ((success_count++))
    else
      echo -e "   ${RED}❌ Failed to convert $file${NC}"
      errors+=("$file: Mix task failed")
      ((error_count++))
    fi

    echo ""
  done

  # Print summary
  echo -e "${BLUE}📊 Conversion Summary:${NC}"
  echo -e "   ${GREEN}✅ Successful: $success_count${NC}"
  echo -e "   ${RED}❌ Failed: $error_count${NC}"

  if [ $error_count -gt 0 ]; then
    echo ""
    echo -e "${RED}Errors encountered:${NC}"
    printf '%s\n' "${errors[@]}" | sed 's/^/  • /'
  fi

  if [ $success_count -gt 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 Conversion completed! Check the generated files in: $OUTPUT_DIR${NC}"
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Review the generated Ash resources"
    echo "  2. Update any custom validations or business logic"
    echo "  3. Test the resources with your existing data"
    echo "  4. Gradually replace Ecto usage with Ash actions"
  fi
}

# Run the main function
main "$@"
