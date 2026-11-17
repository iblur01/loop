import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams (mirror the existing decoded tables, PK (deviceId, ts)).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v4") { db in
            // Server-derived metrics cached locally (Task 3.1: History = union(phone, server)).
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams (mirrors rawBatch.syncedAt).
            // The OLD upload path used a forward-only highwater per stream, which permanently
            // stranded backfilled (older-ts) rows once the highwater jumped to a recent ts.
            // The fix: `synced` is set to 1 only after a successful upload, so the Uploader can
            // drain WHERE synced=0 regardless of ts order. Existing rows default to 0 → they
            // re-upload once (idempotent server-side), catching up the currently-stranded rows.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the dense BATTERY_LEVEL-event battery series (nullable: the
            // command-response battery path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep signal aggregates cached from /v1/daily so the Sleep tab can display
            // SpO2, skin-temperature deviation, and respiration rate without a network round-trip.
            // All three are nullable: they require sufficient raw biometric data on the server.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        migrator.registerMigration("v8") { db in
            // Structured advice signals persisted per-day for M2 coach consumption.
            // Natural key (deviceId, day, code): one row per day per signal code.
            try db.create(table: "adviceSignal") { t in
                t.column("deviceId",   .text).notNull()
                t.column("day",        .text).notNull()   // YYYY-MM-DD
                t.column("code",       .text).notNull()   // e.g. "SLEEP_DEBT"
                t.column("paramsJSON", .text).notNull()   // JSON-serialised params dict
                t.column("confidence", .text).notNull()   // "low"|"medium"|"high"
                t.primaryKey(["deviceId", "day", "code"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Séances importées depuis des sources externes (v1 : Apple Santé). PK = identifiant
            // de la source (UUID HKWorkout), donc l'upsert est idempotent.
            try db.create(table: "external_workout") { t in
                t.primaryKey("id", .text)
                t.column("source",      .text).notNull()      // "healthkit"
                t.column("sportType",   .integer).notNull()   // HKWorkoutActivityType.rawValue
                t.column("startDate",   .double).notNull()    // epoch seconds
                t.column("endDate",     .double).notNull()
                t.column("durationSec", .double).notNull()
                t.column("energyKcal",  .double)
                t.column("distanceM",   .double)
                t.column("sourceName",  .text)
                t.column("importedAt",  .double).notNull()
            }
            try db.create(index: "external_workout_startDate", on: "external_workout", columns: ["startDate"])
            // Ancre de synchronisation incrémentale par source (HKQueryAnchor archivée).
            try db.create(table: "external_sync_anchor") { t in
                t.primaryKey("source", .text)
                t.column("anchorData", .blob).notNull()
                t.column("updatedAt",  .double).notNull()
            }
        }
        migrator.registerMigration("v10") { db in
            // Échantillons Apple Santé génériques (pas, FC, VFC, énergie, sommeil…). PK = UUID HKSample,
            // donc l'upsert est idempotent. L'ancre par type vit dans external_sync_anchor sous la clé
            // "healthkit:<type>" (l'ancre séances "healthkit" reste inchangée).
            try db.create(table: "health_sample") { t in
                t.primaryKey("uuid", .text)
                t.column("type",           .text).notNull()   // identifiant HK court, ex. "stepCount"
                t.column("startDate",      .double).notNull() // epoch seconds
                t.column("endDate",        .double).notNull()
                t.column("value",          .double)           // quantité, ou valeur de catégorie
                t.column("unit",           .text).notNull()
                t.column("sourceName",     .text)
                t.column("sourceBundle",   .text)
                t.column("metadataOrigin", .text)             // "loop" si écrit par Loop (écriture : plus tard)
                t.column("importedAt",     .double).notNull()
            }
            try db.create(index: "health_sample_type_startDate", on: "health_sample", columns: ["type", "startDate"])
        }
        migrator.registerMigration("v11") { db in
            // A count cannot detect a replacement or a deletion followed by an insertion.
            // These revisions belong to the data, survive restarts and roll back with writes.
            try db.execute(sql: "CREATE TABLE input_revision (id INTEGER PRIMARY KEY CHECK (id = 1), instance TEXT NOT NULL, revision INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO input_revision VALUES (1, lower(hex(randomblob(16))), 0)")
            try db.execute(sql: "CREATE TABLE input_day_revision (day TEXT PRIMARY KEY, revision INTEGER NOT NULL)")
            let sources: [(String, String, String)] = [
                ("hrSample", "ts", "ts"), ("rrInterval", "ts", "ts"),
                ("gravitySample", "ts", "ts"), ("respSample", "ts", "ts"),
                ("spo2Sample", "ts", "ts"), ("skinTempSample", "ts", "ts"),
                ("health_sample", "startDate", "endDate"),
                ("external_workout", "startDate", "endDate")
            ]
            for (table, start, end) in sources {
                for operation in ["INSERT", "DELETE", "UPDATE"] {
                    let rows = operation == "UPDATE" ? ["OLD", "NEW"] : [operation == "DELETE" ? "OLD" : "NEW"]
                    var statements = "UPDATE input_revision SET revision = revision + 1 WHERE id = 1;"
                    for row in rows {
                        if start == end {
                            statements += """
                                INSERT INTO input_day_revision(day, revision)
                                VALUES (date(\(row).\(start), 'unixepoch'), 1)
                                ON CONFLICT(day) DO UPDATE SET revision = revision + 1;
                                """
                        } else {
                            // Include all intersected days, including spans longer than 24 h.
                            statements += """
                                INSERT INTO input_day_revision(day, revision)
                                SELECT day, 1 FROM (
                                    WITH RECURSIVE dates(day) AS (
                                        SELECT date(\(row).\(start), 'unixepoch')
                                        UNION ALL SELECT date(day, '+1 day') FROM dates
                                        WHERE day < date(\(row).\(end), 'unixepoch')
                                    ) SELECT day FROM dates
                                ) WHERE true ON CONFLICT(day) DO UPDATE SET revision = revision + 1;
                                """
                        }
                    }
                    try db.execute(sql: "CREATE TRIGGER revision_\(table)_\(operation.lowercased()) AFTER \(operation) ON \(table) BEGIN \(statements) END")
                }
            }
        }
        migrator.registerMigration("v12") { db in
            // RPE (perception d'effort 1-10) saisi par l'utilisateur, par séance. `workoutId` est
            // l'identifiant stable de la séance (ex. "external:<uuid HealthKit>"). Pas de clé
            // étrangère : la séance peut être supprimée/réimportée sans perdre la saisie.
            try db.create(table: "workout_perceived_effort") { t in
                t.primaryKey("workoutId", .text)
                t.column("rpe",        .integer).notNull().check { $0 >= 1 && $0 <= 10 }
                t.column("recordedAt", .double).notNull()   // epoch seconds
                t.column("note",       .text)
            }
        }
        migrator.registerMigration("v13") { db in
            // Cache local des données Apple Santé complémentaires d'une séance (tracé GPS, série FC),
            // lues à la demande à l'ouverture du détail. `workoutKey` = clé stable de la séance
            // ("external:<uuid>" / "band:<deviceId>:<startTs>"). Cache dérivé : pas de trigger
            // input_revision (n'entre pas dans les calculs). Inclus dans .loopbackup (copie de la base).
            try db.create(table: "workout_route_point") { t in
                t.column("workoutKey",         .text).notNull()
                t.column("idx",                .integer).notNull()
                t.column("timestamp",          .double).notNull()   // epoch seconds
                t.column("latitude",           .double).notNull()
                t.column("longitude",          .double).notNull()
                t.column("altitude",           .double)             // m, nil si inconnue
                t.column("horizontalAccuracy", .double)             // m, nil si inconnue
                t.primaryKey(["workoutKey", "idx"])
            }
            try db.create(table: "workout_heart_series") { t in
                t.column("workoutKey", .text).notNull()
                t.column("ts",         .double).notNull()           // début de fenêtre 5 s, epoch seconds
                t.column("bpm",        .double).notNull()
                t.primaryKey(["workoutKey", "ts"])
            }
            // Statut de la dernière lecture par (séance, type) : "loaded" ou "unavailable"
            // (séance sans tracé = cas fréquent, mémorisé pour ne pas réinterroger Santé).
            try db.create(table: "workout_detail_fetch") { t in
                t.column("workoutKey",  .text).notNull()
                t.column("kind",        .text).notNull()            // "route" | "heart"
                t.column("state",       .text).notNull()            // "loaded" | "unavailable"
                t.column("sourceCount", .integer).notNull()         // points lus avant décimation
                t.column("fetchedAt",   .double).notNull()
                t.primaryKey(["workoutKey", "kind"])
            }
        }
        migrator.registerMigration("v14") { db in
            // Existing workouts keep unknown provenance; no historical bundle can be inferred.
            try db.alter(table: "external_workout") { t in
                t.add(column: "sourceBundle", .text)
            }
        }
        migrator.registerMigration("v15") { db in
            // Stable device identity (HKSourceRevision.productType, HKDevice.model) to classify sources
            // without relying on the localized, user-renamable source name. Existing rows stay nil.
            try db.alter(table: "health_sample") { t in
                t.add(column: "productType", .text)
                t.add(column: "deviceModel", .text)
            }
            try db.alter(table: "external_workout") { t in
                t.add(column: "productType", .text)
                t.add(column: "deviceModel", .text)
            }
            // One-shot catch-up without deleting anything: anchors from before v15 have a NULL
            // identityVersion and are ignored by the reader, so the next sync re-imports history
            // (idempotent upserts by UUID) and writes a versioned anchor that is honored afterwards.
            try db.alter(table: "external_sync_anchor") { t in
                t.add(column: "identityVersion", .integer)
            }
        }
        return migrator
    }
}
