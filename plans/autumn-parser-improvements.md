# Autumn Parser Improvements — codedb_custom

> Potential improvements to `src/autumn_parser.zig` for better Autumn project intelligence.

## Current State

The parser extracts 9 symbol kinds across 4 file types:
- `.adm`: entity_schema, entity, entity_attribute
- `.acfg`: configuration, database_catalog, message_queue
- `.adpt`: component (state machine nodes only)
- `.arc`: rule_set, rule_reference

## Proposed Improvements

### 1. .adpt — Extract Transitions (HIGH IMPACT)

Transitions define the workflow edges. Currently we see the nodes but not the flow.

```xml
<transition toState="Create Process" />
<transition toState="Email Error" condition="ERROR-COUNT != 0" />
```

**Proposal:** Add a `transition` kind that captures the `toState` and optional `condition`. This would let agents reconstruct the full state machine from the outline alone.

### 2. .adpt — Extract Key Settings Per Component Type (HIGH IMPACT)

Different component types have critical settings that define their behavior:

| Component Type | Key Settings |
|---------------|--------------|
| Execute Ruleset | `Statement` (contains `@RuleSetName = '...'`) |
| HTTP | `Uri` (the API endpoint), `Verb` (GET/POST) |
| FileListener | `Path` (watch directory), `Pattern` (file pattern) |
| FileCopy | `SourceFileName`, `TargetFileNameOrDir` |
| ETL | `DefinitionName`, `DefinitionsFileName` |
| Email | `Subject`, `To` |

**Proposal:** Parse the `Statement` field in SQL Execute components to extract the `@RuleSetName` value. This creates a direct link from adapter → rule set name.

### 3. .adpt — Extract Terminate States (MEDIUM IMPACT)

```xml
<terminate isError="true" name="Failure" />
<terminate isError="false" name="Done" />
```

**Proposal:** Add a `terminate` kind with `isError` flag.

### 4. .adm — Extract Entity Schema Reference (MEDIUM IMPACT)

Currently extracts entity name but not which schema it belongs to:

```xml
<entity schema="SCH|Audit" entityName="CommandLog" entityTypeId="Table">
```

**Proposal:** Add the schema (stripped of "SCH|" prefix) to the entity's detail field. Also add `entityTypeId` (Table/View/Function).

### 5. .adm — Extract Domain Definitions (LOW IMPACT)

```xml
<domainListDefinition domainType="Standard" description="..." name="Rule Type" value="12">
```

These define the domain enums used throughout the model. Currently not extracted.

### 6. .acfg — Extract Template Variables (LOW IMPACT)

The `{{varName}}` patterns in .acfg files are the cross-file glue between config and adapters. Extracting them as symbols would help trace configuration dependencies.

### 7. .acfg — Extract Host/DBC References (LOW IMPACT)

```
host="HOST|Azure Credo Apps"
databaseCatalog="DBC|Autumn Database Server|SQLServer|AutumnDotNet"
```

These reference infrastructure definitions. Extracting them would help map adapter → infrastructure dependencies.

---

## Priority Order

1. **.adpt transitions** — most impactful, enables workflow reconstruction
2. **.adpt key settings** — especially RuleSetName extraction from SQL components
3. **.adm schema reference** — cheap to add, high value for entity navigation
4. **.adpt terminate states** — cheap to add, completes the state machine picture
5. **.adm domain definitions** — useful for understanding domain enums
6. **.acfg template variables** — useful but complex (multi-line values)
7. **.acfg host/DBC references** — useful but low frequency of use

---

## Implementation Notes

All improvements are additive — no existing symbol kinds change. New kinds would be:
- `transition` (in .adpt)
- `terminate` (in .adpt)
- `domain_definition` (in .adm)
- `template_variable` (in .acfg)

The existing `component` kind in .adpt would gain richer detail (componentType name, key settings).
