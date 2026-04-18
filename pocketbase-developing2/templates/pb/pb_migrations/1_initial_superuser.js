migrate((app) => {
    let superusers = app.findCollectionByNameOrId("_superusers")

    let record = new Record(superusers)
    record.set("email", $os.getenv("PB_ADMIN_EMAIL"))
    record.set("password", $os.getenv("PB_ADMIN_PASSWORD"))

    app.save(record)
}, (app) => {
    try {
        let record = app.findAuthRecordByEmail("_superusers", $os.getenv("PB_ADMIN_EMAIL"))
        app.delete(record)
    } catch {
        // silent errors (probably already deleted)
    }
})
