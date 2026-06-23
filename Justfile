migrationDate := `date -u '+%Y%m%d%H%M%S'`

# Show available recipes
default:
  just --list

# Create new migration file with timestamp
[group("database")]
make-migration name:
  touch en-migrations/db/migrations/{{migrationDate}}_{{name}}.sql
