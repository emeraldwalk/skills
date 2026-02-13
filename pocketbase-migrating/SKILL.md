---
name: pocketbase-migrating
description: Generates migration boilerplate, inspects live schema, and validates PocketBase migrations. Use when creating or modifying PocketBase collections, authoring migration files, inspecting current schema, or debugging migration errors.
---

# PocketBase Schema

Tooling for authoring, inspecting, and validating PocketBase schema migrations. For server lifecycle operations (init, dev, stop, reset), see the **pocketbase** skill.

## Prerequisites

- PocketBase project already initialized (via `pocketbase` skill's **PB Init**)
- Go 1.23+ installed and on PATH
- For **Inspect**: PocketBase server must be running (via `pb-dev.sh` or `pb-reset.sh`)

## Operations

| Operation           | Script                                                                                       | Description                                              |
| ------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| **Migrate Create**  | `bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh <description> [type]` | Generate a timestamped migration file with boilerplate   |
| **Schema Inspect**  | `bash .github/skills/pocketbase-migrating/scripts/pb-schema-inspect.sh [collection-name]`    | Dump live schema as JSON (all collections or one)        |
| **Schema Validate** | `bash .github/skills/pocketbase-migrating/scripts/pb-schema-validate.sh`                     | Wipe data and dry-run all migrations to check for errors |

### Migrate Create

Generates a new migration file in `pb/pb_migrations/` with the correct timestamp and boilerplate.

```bash
# Create a new collection
bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh create_posts create

# Modify an existing collection
bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh add_featured_to_posts modify

# Seed data into a collection
bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh seed_categories seed
```

The `type` argument selects the boilerplate template:

- **`create`** (default): `new Collection(...)` skeleton with commented field examples
- **`modify`**: `findCollectionByNameOrId()` skeleton with add/remove/modify examples
- **`seed`**: Record insertion skeleton

After generating, edit the file to fill in collection name and fields.

### Schema Inspect

Requires the server to be running.

```bash
# Dump all collections
bash .github/skills/pocketbase-migrating/scripts/pb-schema-inspect.sh

# Dump a specific collection
bash .github/skills/pocketbase-migrating/scripts/pb-schema-inspect.sh posts
```

### Schema Validate

Stops the server, wipes `pb_data`, and runs all migrations to check for errors. Does NOT restart the server — run `pb-reset.sh` or `pb-dev.sh` afterward.

```bash
bash .github/skills/pocketbase-migrating/scripts/pb-schema-validate.sh
```

## Workflow

Follow this loop when adding or modifying collections:

1. **Inspect** current schema to understand what exists
   ```bash
   bash .github/skills/pocketbase-migrating/scripts/pb-schema-inspect.sh
   ```
2. **Generate** a migration boilerplate
   ```bash
   bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh create_posts create
   ```
3. **Edit** the generated file — fill in collection name, fields, rules, and indexes
4. **Validate** — dry-run all migrations to catch errors
   ```bash
   bash .github/skills/pocketbase-migrating/scripts/pb-schema-validate.sh
   ```
5. **Reset & verify** — start fresh server and check admin dashboard
   ```bash
   bash .github/skills/pocketbase-managing/scripts/pb-reset.sh
   ```

## Migration Authoring Rules

These rules prevent the most common agent mistakes. Follow them strictly.

### Relations: Always Look Up Collection IDs

**Never** hardcode a `collectionId`. Always resolve it at migration time:

```javascript
migrate((app) => {
  const users = app.findCollectionByNameOrId('users')

  const collection = new Collection({
    name: 'posts',
    type: 'base',
    fields: [
      new RelationField({
        name: 'author',
        collectionId: users.id, // CORRECT: resolved at runtime
        maxSelect: 1,
        cascadeDelete: false,
      }),
    ],
  })
  app.save(collection)
})
```

### Migration Ordering

- Files run in **filename order** (lexicographic by timestamp prefix)
- A migration that references another collection must come **after** the migration that creates it
- Use `pb-migrate-create.sh` to get correct timestamps — do NOT manually set timestamps

### Always Write DOWN Migrations

Every `migrate()` call takes two callbacks: UP and DOWN. Always implement both:

```javascript
migrate(
  (app) => {
    // UP: create or modify
  },
  (app) => {
    // DOWN: reverse the UP changes
  },
)
```

### Auth Collections

Auth collections get system fields automatically (`email`, `emailVisibility`, `verified`, `password`, `tokenKey`). Do not re-declare them. Only add your custom fields:

```javascript
const collection = new Collection({
  type: 'auth',
  name: 'users',
  fields: [
    new TextField({ name: 'displayName', max: 100 }),
    // email, password, etc. are added automatically
  ],
  passwordAuth: { enabled: true },
})
```

### View Collections

View collections are read-only and backed by a SQL SELECT:

```javascript
const collection = new Collection({
  type: 'view',
  name: 'posts_with_authors',
  viewQuery:
    'SELECT p.id, p.title, u.displayName as author FROM posts p JOIN users u ON p.author = u.id',
  // listRule / viewRule apply; create/update/delete rules are ignored
})
```

## Common Mistakes

| Mistake                                                  | Fix                                                            |
| -------------------------------------------------------- | -------------------------------------------------------------- |
| Hardcoded `collectionId: "abc123"`                       | Use `app.findCollectionByNameOrId("name").id`                  |
| Migration references a collection that doesn't exist yet | Ensure the creating migration has an earlier timestamp         |
| Re-declaring `email`, `password` on auth collections     | These are system fields — they exist automatically             |
| Missing DOWN migration                                   | Always implement the second callback to `migrate()`            |
| Using `$app` instead of `app`                            | The callback parameter is `app`, not `$app`                    |
| Setting rules to `undefined` or omitting them            | Use `null` (superuser only), `""` (public), or a filter string |
| `new Field(...)` instead of `new TextField(...)`         | Use the specific constructor: `TextField`, `NumberField`, etc. |
| Manually naming migration files                          | Always use `pb-migrate-create.sh` for correct timestamps       |

## Reference

For field types, API rules, and the full JS migration API, see the **pocketbase** skill's [references/migrations.md](../pocketbase/references/migrations.md).
