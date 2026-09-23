# Core Data

- Use `CoreDataStack` background contexts for writes; keep managed objects on their owning context and merge updates for UI reads.
- Consult `../StockbarDataModel.xcdatamodeld/.xccurrentversion` for the current schema. Schema versions and `DataMigrationService` data-migration flags are separate.
- Preserve migration paths and portfolio/position snapshot relationships. Check cascades before changing deletion behavior.
- Use existing batch/context helpers for large histories. Tests must use isolated temporary or in-memory stores, never the production database.
- Read [recovery procedures](../../../Scripts/README.md) before operational store changes.
