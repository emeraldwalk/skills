# JS Migration Reference

Migration files live in `pb/pb_migrations/` and run in filename order on server start.

## File Naming

```
pb_migrations/{unix_timestamp}_{description}.js
```

Example: `pb_migrations/1687801097_create_posts.js`

To generate a new migration file via CLI:

```bash
go -C pb run . migrate create "description_here"
```

## Migration Structure

```javascript
migrate((app) => {
  // UP — apply changes
}, (app) => {
  // DOWN — revert changes (optional but recommended)
})
```

Both callbacks receive a transactional `app` instance.

## Create a Collection

```javascript
migrate((app) => {
  const collection = new Collection({
    type: "base",          // "base", "auth", or "view"
    name: "posts",
    listRule: "@request.auth.id != ''",
    viewRule: "@request.auth.id != ''",
    createRule: "@request.auth.id != ''",
    updateRule: "author = @request.auth.id",
    deleteRule: "author = @request.auth.id",
    fields: [
      new TextField({ name: "title", required: true, max: 200 }),
      new EditorField({ name: "body" }),
      new SelectField({ name: "status", values: ["draft", "published"], maxSelect: 1 }),
      new RelationField({
        name: "author",
        collectionId: "COLLECTION_ID_HERE",
        maxSelect: 1,
        cascadeDelete: false
      }),
      new AutodateField({ name: "created", onCreate: true, onUpdate: false }),
      new AutodateField({ name: "updated", onCreate: true, onUpdate: true }),
    ],
    indexes: [
      "CREATE INDEX idx_posts_status ON posts (status)",
    ],
  })
  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("posts")
  app.delete(collection)
})
```

## Default Users Collection

PocketBase automatically creates a `users` auth collection on init with these fields: `name` (text), `avatar` (file), `email` (system), `password` (system), `verified` (system), `created`, `updated`. Do NOT create a new `users` collection — modify the existing one if needed.

## Modify an Existing Collection

```javascript
migrate((app) => {
  const collection = app.findCollectionByNameOrId("posts")

  // Add a field
  collection.fields.add(new BoolField({ name: "featured" }))

  // Remove a field
  collection.fields.removeByName("old_field")

  // Modify a field
  const titleField = collection.fields.getByName("title")
  titleField.max = 500

  // Update API rules
  collection.listRule = ""

  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("posts")
  collection.fields.removeByName("featured")
  collection.listRule = "@request.auth.id != ''"
  app.save(collection)
})
```

## Relation Lookup by Name

When creating relations, you need the target collection's ID. Look it up by name:

```javascript
migrate((app) => {
  const users = app.findCollectionByNameOrId("users")

  const collection = new Collection({
    type: "base",
    name: "posts",
    fields: [
      new TextField({ name: "title", required: true }),
      new RelationField({
        name: "author",
        collectionId: users.id,     // resolved at migration time
        maxSelect: 1,
        cascadeDelete: false,
      }),
    ],
  })
  app.save(collection)
})
```

## Seed Data in Migrations

```javascript
migrate((app) => {
  const collection = app.findCollectionByNameOrId("categories")
  for (const name of ["Work", "Personal", "Shopping"]) {
    const record = new Record(collection)
    record.set("name", name)
    app.save(record)
  }
})
```

## Raw SQL

```javascript
migrate((app) => {
  app.db().newQuery("UPDATE posts SET status = 'draft' WHERE status = ''").execute()
})
```

## Field Types Quick Reference

| Constructor | Key Options |
|-------------|-------------|
| `TextField` | `required`, `min`, `max`, `pattern` |
| `NumberField` | `required`, `min`, `max`, `onlyInt` |
| `BoolField` | `required` |
| `EmailField` | `required`, `onlyDomains`, `exceptDomains` |
| `URLField` | `required`, `onlyDomains`, `exceptDomains` |
| `DateField` | `required` |
| `AutodateField` | `onCreate`, `onUpdate` |
| `SelectField` | `values` (required), `maxSelect` |
| `FileField` | `maxSelect`, `maxSize`, `mimeTypes`, `thumbs`, `protected` |
| `RelationField` | `collectionId` (required), `maxSelect`, `cascadeDelete` |
| `JSONField` | `required` (nullable unlike other fields) |
| `EditorField` | `required`, `maxSize`, `convertURLs` |
| `PasswordField` | `required`, `min`, `max`, `cost` |
| `GeoPointField` | `required` |

## API Rules Quick Reference

| Value | Meaning |
|-------|---------|
| `null` | Superuser only (locked) |
| `""` | Public access (no auth required) |
| `"@request.auth.id != ''"` | Any authenticated user |
| `"author = @request.auth.id"` | Owner only (field `author` matches current user) |
| `"@request.auth.verified = true"` | Verified users only |

Rules support: `=`, `!=`, `>`, `>=`, `<`, `<=`, `~` (contains), `!~`, `&&`, `||`

For multi-value relation checks use `?=`: `"members ?= @request.auth.id"`
