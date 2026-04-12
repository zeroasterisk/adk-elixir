---
name: Ecto
description: "Use this skill working with Ecto or any of its extensions. Always consult this when making any domain changes, features or fixes."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [ecto](references/ecto.md)
- [ecto_sql](references/ecto_sql.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ecto -p ecto_sql
```

## Available Mix Tasks

- `mix ecto` - Prints Ecto help information
- `mix ecto.create` - Creates the repository storage
- `mix ecto.drop` - Drops the repository storage
- `mix ecto.gen.repo` - Generates a new repository
- `mix ecto.dump` - Dumps the repository database structure
- `mix ecto.gen.migration` - Generates a new migration for the repo
- `mix ecto.load` - Loads previously dumped database structure
- `mix ecto.migrate` - Runs the repository migrations
- `mix ecto.migrations` - Displays the repository migration status
- `mix ecto.rollback` - Rolls back the repository migrations
<!-- usage-rules-skill-end -->
