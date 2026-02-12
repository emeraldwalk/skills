#!/bin/bash
# pb-migrate-create.sh: Generate a timestamped PocketBase migration boilerplate file
# Usage: bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh <description> [type]
#   description: snake_case name (e.g. create_posts, add_featured_to_posts)
#   type: create (default), modify, or seed
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/../../../.."
MIGRATIONS_DIR="$ROOT_DIR/pb/pb_migrations"

DESCRIPTION="${1:-}"
TYPE="${2:-create}"

if [ -z "$DESCRIPTION" ]; then
  echo "Error: description is required."
  echo "Usage: bash .github/skills/pocketbase-migrating/scripts/pb-migrate-create.sh <description> [type]"
  echo "  type: create (default), modify, or seed"
  exit 1
fi

# Ensure migrations directory exists
mkdir -p "$MIGRATIONS_DIR"

# Generate timestamp
TIMESTAMP=$(date +%s)
FILENAME="${TIMESTAMP}_${DESCRIPTION}.js"
FILEPATH="$MIGRATIONS_DIR/$FILENAME"

case "$TYPE" in
  create)
    cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = new Collection({
    type: "base",          // "base", "auth", or "view"
    name: "COLLECTION_NAME",
    listRule: null,        // null = superuser only, "" = public, "@request.auth.id != ''" = any auth
    viewRule: null,
    createRule: null,
    updateRule: null,
    deleteRule: null,
    fields: [
      // new TextField({ name: "title", required: true, min: 1, max: 200 }),
      // new NumberField({ name: "count", required: false, min: 0, onlyInt: true }),
      // new BoolField({ name: "active" }),
      // new EmailField({ name: "contactEmail" }),
      // new URLField({ name: "website" }),
      // new EditorField({ name: "body", required: true }),
      // new DateField({ name: "publishedAt" }),
      // new AutodateField({ name: "created", onCreate: true, onUpdate: false }),
      // new AutodateField({ name: "updated", onCreate: true, onUpdate: true }),
      // new SelectField({ name: "status", values: ["draft", "published"], maxSelect: 1, required: true }),
      // new FileField({ name: "avatar", maxSelect: 1, maxSize: 5242880, mimeTypes: ["image/jpeg", "image/png"] }),
      // new JSONField({ name: "metadata" }),
      // new GeoPointField({ name: "location" }),

      // Relations — ALWAYS look up the target collection ID at runtime:
      // const targetCol = app.findCollectionByNameOrId("target_collection_name")
      // new RelationField({ name: "author", collectionId: targetCol.id, maxSelect: 1, cascadeDelete: false }),
    ],
    indexes: [
      // "CREATE INDEX idx_COLLECTION_NAME_field ON COLLECTION_NAME (field)",
      // "CREATE UNIQUE INDEX idx_COLLECTION_NAME_field ON COLLECTION_NAME (field)",
    ],
  })
  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")
  app.delete(collection)
})
MIGEOF
    ;;

  modify)
    cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  // Add a field:
  // collection.fields.add(new TextField({ name: "subtitle", max: 200 }))

  // Remove a field:
  // collection.fields.removeByName("old_field")

  // Modify an existing field (returns a reference):
  // const titleField = collection.fields.getByName("title")
  // titleField.max = 500

  // Update API rules:
  // collection.listRule = "@request.auth.id != ''"

  // Add an index:
  // collection.addIndex("idx_name", false, "field_name", "")

  app.save(collection)
}, (app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  // Reverse changes here

  app.save(collection)
})
MIGEOF
    ;;

  seed)
    cat > "$FILEPATH" << 'MIGEOF'
/// <reference path="../pb_data/types.d.ts" />

migrate((app) => {
  const collection = app.findCollectionByNameOrId("COLLECTION_NAME")

  const records = [
    // { field1: "value1", field2: "value2" },
  ]

  for (const data of records) {
    const record = new Record(collection)
    for (const [key, value] of Object.entries(data)) {
      record.set(key, value)
    }
    app.save(record)
  }
}, (app) => {
  // Optional: delete seeded records
  // const collection = app.findCollectionByNameOrId("COLLECTION_NAME")
  // const records = app.findRecordsByFilter(collection, "field1 = 'value1'", "", 0, 0)
  // for (const record of records) {
  //   app.delete(record)
  // }
})
MIGEOF
    ;;

  *)
    echo "Error: unknown type '$TYPE'. Use: create, modify, or seed"
    exit 1
    ;;
esac

echo "Created: pb/pb_migrations/$FILENAME"
echo "Next: edit the file to fill in your collection name and fields, then validate with:"
echo "  bash .github/skills/pocketbase-migrating/scripts/pb-schema-validate.sh"
