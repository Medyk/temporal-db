# explain fill_factor=70 and 8kB page

PostgreSQL stores all table data in fixed 8 KB (8,192-byte) disk pages, uses fillfactor = 70 to reserve 30% of each page so updated row versions stay on the same page (enabling zero-index-write HOT updates), and automatically compresses or offloads columns via TOAST whenever a row exceeds roughly 2 KB.
1. Anatomy of an 8 KB Heap Page

Every table in PostgreSQL is an array of 8,192-byte blocks (pages). When PostgreSQL reads or modifies even a single column of a single row, it loads the entire 8 KB page into shared memory (shared_buffers).

Inside each 8 KB page, data grows from both ends toward the middle:

    Page Header (24 bytes at the top): Tracks transaction visibility flags, Write-Ahead Log (WAL) position (pd_lsn), and the byte offsets marking the start and end of free space.

    Line Pointers / Item IDs (4 bytes each, growing downward): An array of 4-byte offsets pointing to the actual tuples at the bottom of the page. Crucially, indexes never point directly to a row's byte offset; an index points to ctid = (page_number, line_pointer_number).

    Unallocated Free Space (in the middle): Empty space available for new rows or updated versions of existing rows on this page.

    Heap Tuples (growing upward from the bottom): The actual row versions. Every row carries a 23-byte header (HeapTupleHeaderData, padded to 24 bytes) containing its creation transaction (xmin), deletion/update transaction (xmax), and pointer to the next version (t_ctid), followed by the column bytes.

2. How fillfactor = 70 Enables HOT Updates and Zero-Vacuum Cleanup

By default, PostgreSQL sets fillfactor = 100, packing each 8 KB page completely full during INSERT operations. When you later UPDATE a row on a 100%-full page, the new row version cannot fit on the same page:

    PostgreSQL writes the new tuple to a different 8 KB page.

    Because the page number changed, PostgreSQL must insert a brand-new entry into every index on the table.

    The old tuple and old index entries remain behind until autovacuum scans both the table and all indexes.

When you set WITH (fillfactor = 70) on main_table_current:

    30% Reserved Space (~2,458 bytes): PostgreSQL stops inserting new rows into a page once it reaches 70% capacity (~5,734 bytes), saving the remaining 30% exclusively for UPDATEs to rows already on that page.

    Heap-Only Tuple (HOT) Update: Because entity_update never modifies the indexed column (uuid) and the new tuple fits into the reserved 30% space on the exact same 8 KB page, the index is never touched. The index continues pointing to Line Pointer 1, which links via an internal page chain (Line Pointer 1 -> Line Pointer 2) to the updated tuple.

    Single-Page Pruning (Self-Cleaning without VACUUM): The next time any query reads or updates that 8 KB page, PostgreSQL sees that the old tuple (Line Pointer 1) is no longer visible to any active transaction. It immediately reclaims those bytes in memory during the read, redirects Line Pointer 1 to point straight to the new tuple, and frees the space for the next UPDATE.

3. What Happens When a Table Has Many Columns or a Row Exceeds 8 KB?

PostgreSQL never allows a single main-table tuple to span across two 8 KB pages, and it enforces a hard limit of 1,600 columns per table. To ensure multiple rows always fit on a single page, PostgreSQL enforces a threshold called TOAST_TUPLE_THRESHOLD (~2,034 bytes, or roughly 1/4 of an 8 KB page).

What happens depends on whether the row size comes from variable-length columns (TEXT, VARCHAR, JSONB, BYTEA) or hundreds of fixed-length columns (BIGINT, TIMESTAMPTZ, UUID, NUMERIC).

| Row Characteristic                                                 | In-Line Size on 8 KB Page                                   | How PostgreSQL Handles It                                                                               | Impact on main_table_current (Solution 1)                                                                                                                    |
|--------------------------------------------------------------------|-------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Narrow row (less than 2,000 bytes)                               | Actual row size (e.g., 100–500 bytes)                     | Stored 100% in-line on the 8 KB page                                                                    | Ideal: Dozens of rows fit per page; 100% HOT updates                                                                                                         |
| Large TEXT / JSONB / BYTEA (2 KB up to 1 GB per column)            | Shrunk to an 18-byte TOAST pointer                          | Compressed (lz4/pglz); if still greater than 2 KB, sliced into 2 KB chunks in a hidden pg_toast table | Warning: Main page stays tiny (HOT works), but moving the row to main_table_history copies TOAST chunks and leaves dead TOAST tuples in main_table_current |
| Many fixed-size columns (e.g., 300 BIGINT columns = 2,400 bytes) | Cannot be TOASTed; full 2,400 bytes stay on the 8 KB page | Allowed up to 8,160 bytes (MaxHeapTupleSize); errors out if in-line bytes exceed 8,160                | Breaks HOT if greater than 4,000 bytes: Old tuple + new tuple exceed 8,192 bytes and cannot coexist on the same page                                       |

Two Hidden Traps with Wide Rows in Solution 1

    1. The 4 KB In-Line Tuple Limit for HOT Updates:
    For a HOT update to succeed, the old tuple and the new tuple must coexist on the same 8 KB page simultaneously until the transaction commits and single-page pruning reclaims the old tuple. If your table has so many fixed-length columns (which cannot be offloaded to TOAST) that a single row consumes more than 4,080 bytes on the main page, two versions of the row cannot fit in 8,192 bytes—even if fillfactor = 50. Every UPDATE will spill to a new page.

    2. Double-TOAST Copy & TOAST Bloat on entity_update:
    Each table has its own private pg_toast companion table. In Solution 1, if some_data is a 50 KB string stored out-of-line in main_table_current's TOAST table, running entity_update forces PostgreSQL to:

        Copy those 50 KB of TOAST chunks from main_table_current's TOAST table into main_table_history's TOAST table.

        Mark the 50 KB of old chunks in main_table_current's TOAST table as dead tuples (and TOAST tables do not use HOT updates because their chunk IDs are indexed).

4. How to Fix Wide/Large Rows (Guaranteed 52-Byte HOT Updates & Zero TOAST Bloat)

If your rows have many columns or payloads exceeding 2 KB, make one small adjustment to Solution 1: store the column data once in an INSERT-only revision data table (main_table_data), and keep only the temporal pointers in main_table_current and main_table_history.

    main_table_data (100% INSERT-only): Holds (uuid, revision, col1, col2, ...) or large TOASTed columns. A revision's data is written once when created and never copied, moved, or updated when the revision closes. Its pg_toast table accumulates zero dead tuples.

    main_table_current (Fixed 52 bytes per row): Holds only (uuid, revision, revision_from)—28 bytes of data + 24 bytes of tuple header = 52 bytes total, regardless of whether your entity has 100 columns or a 100 MB payload. Over 100 active rows fit on a single 8 KB page, and fillfactor = 70 guarantees 100% HOT updates.

```sql
-- 1. INSERT-only payload table (written once on create/update, NEVER updated or copied)
CREATE TABLE main_table_data (
    uuid      UUID NOT NULL REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision  INT  NOT NULL,
    -- Put as many columns or large TEXT/JSONB payloads here as needed (use LZ4 compression in PG 18)
    some_data TEXT COMPRESSION lz4,
    CONSTRAINT pk_main_table_data PRIMARY KEY (uuid, revision)
);

-- 2. Fixed 52-byte active pointer table (100% HOT updates guaranteed, zero TOAST table)
CREATE TABLE main_table_current (
    uuid          UUID        PRIMARY KEY REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision      INT         NOT NULL,
    revision_from TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_current_data FOREIGN KEY (uuid, revision)
        REFERENCES main_table_data (uuid, revision) ON DELETE RESTRICT
) WITH (fillfactor = 70);

-- 3. Fixed-size INSERT-only history range table (zero TOAST table, fast GiST scans)
CREATE TABLE main_table_history (
    uuid        UUID      NOT NULL REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision    INT       NOT NULL,
    valid_range TSTZRANGE NOT NULL,
    CONSTRAINT pk_main_table_history PRIMARY KEY (uuid, revision),
    CONSTRAINT fk_history_data FOREIGN KEY (uuid, revision)
        REFERENCES main_table_data (uuid, revision) ON DELETE RESTRICT,
    CONSTRAINT uq_main_table_history_no_overlap
        UNIQUE (uuid, valid_range WITHOUT OVERLAPS)
);
```

Interactive 8 KB Page, fillfactor, and TOAST Simulator

Adjust the row size, column composition, and fillfactor below to see how tuples pack inside an 8,192-byte PostgreSQL page, when HOT updates succeed or spill to a new page, and when TOAST offloads oversized data:

\<NOT AVAILABLE>

Sources

    PostgreSQL 18 Documentation — Database Page Layout (8 KB Block & HeapTupleHeaderData): postgresql.org/docs/current/storage-page-layout.html

    PostgreSQL 18 Documentation — TOAST (The Oversized-Attribute Storage Technique): postgresql.org/docs/current/storage-toast.html

    PostgreSQL 18 Documentation — Heap-Only Tuples (HOT) & Single-Page Pruning: postgresql.org/docs/current/storage-hot.html

    PostgreSQL 18 Documentation — Storage Parameters (fillfactor & toast_tuple_target): postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-STORAGE-PARAMETERS

---

# Anonymisation procedure

At 5 TB+ scale, use Declarative Partitioning (PARTITION BY) over Legacy Table Inheritance (INHERITS), and separate the temporal timeline (main_table_current / main_table_history) from the payload table (main_table_data), partitioning main_table_data into 64 or 128 Hash Partitions by uuid (yielding ~40–80 GB chunks).

Wait-free or low-impact anonymization ("XXX"-ing out some_data) requires physical deletion of the pre-anonymized bytes on disk (including out-of-line TOAST chunks) via VACUUM or VACUUM FULL. By isolating some_data inside a hash-partitioned main_table_data, you never touch or lock the GiST temporal indexes during anonymization, and you can vacuum one 40 GB partition at a time instead of locking a 5 TB monolith.
1. Declarative Partitioning (PARTITION BY) vs. Table Inheritance (INHERITS)

Always choose Declarative Partitioning (PARTITION BY HASH or PARTITION BY RANGE) in PostgreSQL 18. Legacy INHERITS should not be used for 5 TB tables:

| Feature                          | Declarative Partitioning (PARTITION BY)                                                                                                          | Legacy Table Inheritance (INHERITS)                                                                                                          |
|----------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| Query Planner Pruning            | Fast run-time and plan-time partition pruning (enable_partition_pruning), handling parameterized queries and JOIN pushdowns.                     | Relies on slow constraint_exclusion scanning every child table's CHECK constraints at plan time; fails on parameterized/prepared statements. |
| Partitionwise Joins & Aggregates | Native enable_partitionwise_join: joins Partition $N$ of main_table_history directly to Partition $N$ of main_table_data in small memory chunks. | Not supported; planner appends all child tables first before joining 5 TB at once.                                                           |
| Write Routing                    | Built-in tuple routing in C on INSERT / UPDATE (microseconds).                                                                                   | Requires custom BEFORE INSERT PL/pgSQL triggers or rules, adding high CPU overhead.                                                          |
| Primary & Foreign Keys           | Native partitioned Primary Keys and Foreign Keys (REFERENCES) across partitioned tables.                                                         | Broken: UNIQUE, PRIMARY KEY, and FOREIGN KEY constraints do not work across an inheritance hierarchy.                                        |

2. How to Partition main_table_data for Anonymization: HASH(uuid) vs. RANGE

When anonymizing an entity (uuid), you typically must scrub every historical revision of that uuid (UPDATE main_table_data SET some_data = 'XXX' WHERE uuid = $1).
- Why PARTITION BY HASH (uuid) (64 or 128 partitions) is Best for Entity Anonymization:
  - Single-Partition Targeting: All revisions (Revision 1 through $N$) for a given uuid live in the exact same partition (~40 GB for a 5 TB table with 128 partitions, or ~80 GB with 64 partitions).
  - Primary Key Compatibility: PostgreSQL requires every unique/primary key on a partitioned table to include all partition key columns. Because uuid is already part of PRIMARY KEY (uuid, revision), PARTITION BY HASH (uuid) works without modifying your primary key or foreign keys.
  - Uniform Chunk Sizes: Hash partitioning distributes UUIDs (including PostgreSQL 18 uuidv7()) evenly across all 64/128 partitions, preventing "hot" or oversized partitions that exceed your target vacuum window.
- When to Use PARTITION BY RANGE (uuid) Instead (With uuidv7):
  Because PostgreSQL 18's uuidv7() embeds a 48-bit millisecond Unix timestamp in the top 6 bytes of the UUID, partitioning by RANGE (uuid) is effectively partitioning by entity creation month/year while still keeping PRIMARY KEY (uuid, revision) intact! If your anonymization job runs by retention age (e.g., "anonymize all entities created in Q1 2024"), RANGE (uuid) puts an entire quarter's cohort into a single partition that can be updated and vacuumed once.

3. Why Separating main_table_data Saves Your Temporal GiST Indexes

If some_data lives inside main_table_history alongside valid_range tstzrange:

    Updating some_data = 'XXX' touches main_table_history.

    Because main_table_history has a GiST index (WITHOUT OVERLAPS), and GiST indexes do not support bulk index tuple deletion algorithms as efficiently as B-trees, vacuuming or running VACUUM FULL on main_table_history requires rebuilding expensive R-tree/GiST structures.

By splitting out main_table_data (uuid, revision, some_data) partitioned by HASH (uuid):

    main_table_current & main_table_history stay 100% untouched during anonymization. Their timestamps, revisions, and GiST indexes never experience dead tuples or VACUUM FULL.

    main_table_data has only one simple B-tree index (PRIMARY KEY (uuid, revision)). Updating some_data = 'XXX' and running VACUUM (or VACUUM FULL / pg_repack) per 40–80 GB partition is fast and isolated.

    Critical GDPR / Security Note on VACUUM vs. VACUUM FULL:
    In PostgreSQL, UPDATE main_table_data SET some_data = 'XXX' writes a new tuple with 'XXX' and marks the old tuple (and its pg_toast chunks) as dead. Standard VACUUM marks that space as reusable for future writes, but the old sensitive plaintext remains physically present in the .1 heap/TOAST files on disk until overwritten. If compliance requires immediate physical erasure from disk blocks after anonymization, you must run VACUUM FULL (or the online extension pg_repack) on the affected partition.

4. Complete PostgreSQL 18 DDL (Hash-Partitioned Payload + Temporal Split)

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 1. Anchor table (immutable entity identity, tracks anonymization timestamp)
CREATE TABLE main_table_anchor (
    uuid          UUID        PRIMARY KEY DEFAULT uuidv7(),
    anonymized_at TIMESTAMPTZ
);

-- 2. Partitioned payload table (5 TB+ split into 64 hash partitions of ~80 GB each)
--    100% INSERT-only during normal operations; updated ONLY during anonymization.
CREATE TABLE main_table_data (
    uuid      UUID NOT NULL REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision  INT  NOT NULL,
    some_data TEXT COMPRESSION lz4,
    CONSTRAINT pk_main_table_data PRIMARY KEY (uuid, revision)
) PARTITION BY HASH (uuid);

-- Generate 64 hash partitions (main_table_data_p00 through main_table_data_p63)
-- Note: fillfactor = 95 leaves a small buffer so 'XXX' anonymization updates
-- (which are smaller than the original some_data) always execute as in-place HOT updates!
DO $$
BEGIN
    FOR i IN 0..63 LOOP
        EXECUTE format(
            'CREATE TABLE main_table_data_p%s PARTITION OF main_table_data
             FOR VALUES WITH (MODULUS 64, REMAINDER %s)
             WITH (fillfactor = 95);',
            lpad(i::text, 2, '0'), i
        );
    END LOOP;
END $$;

-- 3. Active pointer table (tiny fixed 52-byte rows, 0 payload, 100% HOT updates)
CREATE TABLE main_table_current (
    uuid          UUID        PRIMARY KEY
                              REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision      INT         NOT NULL,
    revision_from TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_current_data FOREIGN KEY (uuid, revision)
        REFERENCES main_table_data (uuid, revision) ON DELETE RESTRICT
) WITH (fillfactor = 70);

-- 4. History range table (100% INSERT-only forever, NEVER touched by anonymization)
CREATE TABLE main_table_history (
    uuid        UUID      NOT NULL
                          REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision    INT       NOT NULL,
    valid_range TSTZRANGE NOT NULL,
    CONSTRAINT pk_main_table_history PRIMARY KEY (uuid, revision),
    CONSTRAINT fk_history_data FOREIGN KEY (uuid, revision)
        REFERENCES main_table_data (uuid, revision) ON DELETE RESTRICT,
    CONSTRAINT uq_main_table_history_no_overlap
        UNIQUE (uuid, valid_range WITHOUT OVERLAPS),
    CONSTRAINT chk_history_range_bounded
        CHECK (NOT lower_inf(valid_range) AND NOT upper_inf(valid_range))
) PARTITION BY HASH (uuid);

-- Partition history with the exact same 64 hash buckets to enable Partitionwise Joins
DO $$
BEGIN
    FOR i IN 0..63 LOOP
        EXECUTE format(
            'CREATE TABLE main_table_history_p%s PARTITION OF main_table_history
             FOR VALUES WITH (MODULUS 64, REMAINDER %s);',
            lpad(i::text, 2, '0'), i
        );
    END LOOP;
END $$;

CREATE INDEX idx_main_table_history_valid_range
    ON main_table_history USING GIST (valid_range);

-- 5. Unified View: joins temporal state with partitioned payload table
CREATE VIEW table_view AS
SELECT
    t.uuid,
    t.revision,
    t.revision_from,
    t.revision_to,
    t.valid_range,
    d.some_data
FROM (
    SELECT
        uuid,
        revision,
        revision_from,
        'infinity'::timestamptz AS revision_to,
        tstzrange(revision_from, 'infinity'::timestamptz, '[)') AS valid_range
    FROM main_table_current
    UNION ALL
    SELECT
        uuid,
        revision,
        lower(valid_range) AS revision_from,
        upper(valid_range) AS revision_to,
        valid_range
    FROM main_table_history
) t
JOIN main_table_data d
  ON t.uuid = d.uuid AND t.revision = d.revision;
```

5. PostgreSQL 18 Functions (Create, Update, Delete, and Anonymize)

```sql
-- 1. CREATE: Inserts anchor, payload (routed to 1 hash partition), and active pointer
CREATE OR REPLACE FUNCTION entity_create(
    p_some_data     TEXT,
    p_uuid          UUID        DEFAULT uuidv7(),
    p_revision_from TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS SETOF table_view
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH new_anchor AS (
        INSERT INTO main_table_anchor (uuid)
        VALUES (p_uuid)
        RETURNING uuid
    ),
    ins_data AS (
        INSERT INTO main_table_data (uuid, revision, some_data)
        SELECT uuid, 1, p_some_data FROM new_anchor
        RETURNING uuid, revision, some_data
    ),
    ins_current AS (
        INSERT INTO main_table_current (uuid, revision, revision_from)
        SELECT uuid, revision, p_revision_from FROM ins_data
        RETURNING uuid, revision, revision_from
    )
    SELECT
        c.uuid,
        c.revision,
        c.revision_from,
        'infinity'::timestamptz,
        tstzrange(c.revision_from, 'infinity'::timestamptz, '[)'),
        d.some_data
    FROM ins_current c
    JOIN ins_data d USING (uuid, revision);
END;
$$;

-- 2. UPDATE: Inserts new payload row once, HOT-updates current pointer, inserts closed history range
CREATE OR REPLACE FUNCTION entity_update(
    p_uuid          UUID,
    p_some_data     TEXT,
    p_revision_from TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS SETOF table_view
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH updated_cur AS (
        UPDATE main_table_current
        SET revision      = revision + 1,
            revision_from = p_revision_from
        WHERE main_table_current.uuid = p_uuid
        RETURNING
            old.uuid          AS entity_uuid,
            old.revision      AS old_revision,
            old.revision_from AS old_revision_from,
            new.revision      AS new_revision,
            new.revision_from AS new_revision_from
    ),
    ins_data AS (
        INSERT INTO main_table_data (uuid, revision, some_data)
        SELECT entity_uuid, new_revision, p_some_data
        FROM updated_cur
        RETURNING uuid, revision, some_data
    ),
    ins_history AS (
        INSERT INTO main_table_history (uuid, revision, valid_range)
        SELECT
            entity_uuid,
            old_revision,
            tstzrange(old_revision_from, new_revision_from, '[)')
        FROM updated_cur
    )
    SELECT
        u.entity_uuid,
        u.new_revision,
        u.new_revision_from,
        'infinity'::timestamptz,
        tstzrange(u.new_revision_from, 'infinity'::timestamptz, '[)'),
        d.some_data
    FROM updated_cur u
    JOIN ins_data d ON d.uuid = u.entity_uuid AND d.revision = u.new_revision;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active entity % not found', p_uuid USING ERRCODE = 'no_data_found';
    END IF;
END;
$$;

-- 3. LOGICAL DELETE: Moves pointer from current to history without touching main_table_data!
CREATE OR REPLACE FUNCTION entity_delete(
    p_uuid        UUID,
    p_revision_to TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS SETOF table_view
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH del_cur AS (
        DELETE FROM main_table_current
        WHERE main_table_current.uuid = p_uuid
        RETURNING old.uuid, old.revision, old.revision_from
    ),
    ins_history AS (
        INSERT INTO main_table_history (uuid, revision, valid_range)
        SELECT uuid, revision, tstzrange(revision_from, p_revision_to, '[)')
        FROM del_cur
        RETURNING new.uuid, new.revision, new.valid_range
    )
    SELECT
        h.uuid,
        h.revision,
        lower(h.valid_range),
        upper(h.valid_range),
        h.valid_range,
        d.some_data
    FROM ins_history h
    JOIN main_table_data d USING (uuid, revision);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active entity % not found', p_uuid USING ERRCODE = 'no_data_found';
    END IF;
END;
$$;

-- 4. ANONYMIZE: Scrubs all revisions of a UUID (or array of UUIDs) in main_table_data
--    and returns the affected physical partition names so your job knows which partitions to VACUUM
CREATE OR REPLACE FUNCTION entity_anonymize(
    p_uuids UUID[]
)
RETURNS TABLE (
    partition_name TEXT,
    rows_scrubbed  BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE main_table_anchor
    SET anonymized_at = clock_timestamp()
    WHERE uuid = ANY(p_uuids)
      AND anonymized_at IS NULL;

    RETURN QUERY
    WITH scrubbed AS (
        UPDATE main_table_data
        SET some_data = 'XXX'
        WHERE uuid = ANY(p_uuids)
          AND some_data IS DISTINCT FROM 'XXX'
        RETURNING tableoid::regclass::text AS part_name
    )
    SELECT part_name, count(*)
    FROM scrubbed
    GROUP BY part_name;
END;
$$;
```

Why fillfactor = 95 on main_table_data Makes Anonymization Super Fast

When entity_anonymize replaces a large some_data payload (e.g., 500 bytes in-line or an 18-byte TOAST pointer) with 'XXX' (which is only 4 bytes on disk including its 1-byte varlena header!), the new row is much smaller than the old row. With fillfactor = 95, there is ~400 bytes of free space on every 8 KB heap page—enough to perform dozens of 'XXX' anonymization updates as in-place HOT updates without touching the B-tree primary key index.

Then, during your maintenance window, you can run VACUUM (ANALYZE)—or VACUUM (FULL, ANALYZE) if required to overwrite disk blocks—one partition at a time:

```sql
-- Example: Vacuuming just Partition 12 (~80 GB instead of 5 TB)
VACUUM (VERBOSE, ANALYZE) main_table_data_p12;
```

Interactive 5 TB Partitioning & Vacuum Calculator

Use the simulator below to compare HASH(uuid) vs. RANGE partitioning across partition counts (16 to 256) and inspect the resulting partition size, HOT update headroom, and per-chunk vacuum duration on a 5 TB dataset:

[interactive_visual_im_1f06653ea1bf06fd.html](interactive_visual_im_1f06653ea1bf06fd.html)

Sources

    PostgreSQL 18 Documentation — Table Partitioning (Declarative Partitioning vs. Inheritance): postgresql.org/docs/current/ddl-partitioning.html

    PostgreSQL 18 Documentation — Partition Pruning (enable_partition_pruning): postgresql.org/docs/current/ddl-partitioning.html#DDL-PARTITION-PRUNING

    PostgreSQL 18 Documentation — Partitionwise Joins (enable_partitionwise_join): postgresql.org/docs/current/runtime-config-query.html#GUC-ENABLE-PARTITIONWISE-JOIN

    PostgreSQL 18 Documentation — VACUUM & Per-Partition Maintenance: postgresql.org/docs/current/sql-vacuum.html


---

# RANGE partition

Partitioning main_table_data and main_table_history by RANGE (uuid) using UUIDv7 monthly boundaries offers a major structural advantage: because UUIDv7 embeds a millisecond Unix timestamp in its first 48 bits, sorting and range filtering on the uuid column naturally maps to chronological creation time.

This allows you to partition your 5 TB dataset by time without modifying your primary key (keeping it strictly PRIMARY KEY (uuid, revision)), whereas alternative approaches like partitioning by an expression (uuid_extract_timestamp(uuid)) force you to include the timestamp in every primary and foreign key.

Step 1: The UUIDv7 Boundary Helper Function

Because PostgreSQL 18's native uuidv7() function generates current timestamps with random trailing bits, you need a deterministic helper function to translate a timestamptz month boundary into a precise lower-bound UUIDv7 token (where all sub-millisecond and random bits are zeroed out).

```sql
CREATE OR REPLACE FUNCTION uuidv7_floor(ts TIMESTAMPTZ)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    ms BIGINT;
    hex_str TEXT;
BEGIN
    -- Extract epoch time in milliseconds
    ms := FLOOR(EXTRACT(EPOCH FROM ts) * 1000)::BIGINT;
    
    -- Construct 32-character UUID hex:
    -- 1. 12 hex chars (48-bit timestamp)
    -- 2. '7' (4-bit version 7 identifier)
    -- 3. '000' (12-bit sub-ms zeroed)
    -- 4. '8' (variant bits '10' + 2 zeroed random bits)
    -- 5. 15 zeroed hex chars (60-bit random remainder)
    hex_str := LPAD(TO_HEX(ms), 12, '0') || '70008' || LPAD('', 15, '0');
    
    RETURN hex_str::UUID;
END;
$$;
```

Step 2: DDL for Range-Partitioned Tables

Using PARTITION BY RANGE (uuid) allows main_table_data and main_table_history to maintain standard composite primary keys while routing entities into monthly shards based on their creation timestamp.

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 1. Anchor table (entity identity)
CREATE TABLE main_table_anchor (
    uuid          UUID        PRIMARY KEY DEFAULT uuidv7(),
    anonymized_at TIMESTAMPTZ
);

-- 2. Payload table partitioned by RANGE (uuid)
CREATE TABLE main_table_data (
    uuid      UUID NOT NULL REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision  INT  NOT NULL,
    some_data TEXT COMPRESSION lz4,
    CONSTRAINT pk_main_table_data PRIMARY KEY (uuid, revision)
) PARTITION BY RANGE (uuid);

-- 3. History range table partitioned by RANGE (uuid)
CREATE TABLE main_table_history (
    uuid        UUID      NOT NULL REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision    INT       NOT NULL,
    valid_range TSTZRANGE NOT NULL,
    CONSTRAINT pk_main_table_history PRIMARY KEY (uuid, revision),
    CONSTRAINT uq_main_table_history_no_overlap
        UNIQUE (uuid, valid_range WITHOUT OVERLAPS),
    CONSTRAINT chk_history_range_bounded
        CHECK (NOT lower_inf(valid_range) AND NOT upper_inf(valid_range))
) PARTITION BY RANGE (uuid);

-- 4. Active pointer table (unpartitioned, tiny footprint, 100% HOT updates)
CREATE TABLE main_table_current (
    uuid          UUID        PRIMARY KEY REFERENCES main_table_anchor (uuid) ON DELETE RESTRICT,
    revision      INT         NOT NULL,
    revision_from TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_current_data FOREIGN KEY (uuid, revision)
        REFERENCES main_table_data (uuid, revision) ON DELETE RESTRICT
) WITH (fillfactor = 70);

-- 5. Unified read view
CREATE VIEW table_view AS
SELECT
    t.uuid,
    t.revision,
    t.revision_from,
    t.revision_to,
    t.valid_range,
    d.some_data
FROM (
    SELECT
        uuid,
        revision,
        revision_from,
        'infinity'::timestamptz AS revision_to,
        tstzrange(revision_from, 'infinity'::timestamptz, '[)') AS valid_range
    FROM main_table_current
    UNION ALL
    SELECT
        uuid,
        revision,
        lower(valid_range) AS revision_from,
        upper(valid_range) AS revision_to,
        valid_range
    FROM main_table_history
) t
JOIN main_table_data d
  ON t.uuid = d.uuid AND t.revision = d.revision;
```

Step 3: Automated Partition Provisioning Procedure

To prevent manual management of monthly partitions for your 5 TB dataset, use a PL/pgSQL procedure that provisions partitions and their corresponding GiST indexes automatically.

```sql
CREATE OR REPLACE PROCEDURE create_monthly_partitions(p_start_date DATE, p_months INT)
LANGUAGE plpgsql
AS $$
DECLARE
    curr_date   DATE;
    next_date   DATE;
    part_suffix TEXT;
    sql_data    TEXT;
    sql_history TEXT;
    sql_index   TEXT;
BEGIN
    FOR i IN 0..(p_months - 1) LOOP
        curr_date := p_start_date + (i * INTERVAL '1 month')::INTERVAL;
        next_date := curr_date + INTERVAL '1 month';
        part_suffix := TO_CHAR(curr_date, 'YYYY_MM');

        -- 1. Create monthly data partition with fillfactor = 95 for fast 'XXX' HOT updates
        sql_data := format(
            'CREATE TABLE IF NOT EXISTS main_table_data_%s PARTITION OF main_table_data
             FOR VALUES FROM (uuidv7_floor(%L::timestamptz)) TO (uuidv7_floor(%L::timestamptz))
             WITH (fillfactor = 95);',
            part_suffix, curr_date, next_date
        );
        EXECUTE sql_data;

        -- 2. Create monthly history partition
        sql_history := format(
            'CREATE TABLE IF NOT EXISTS main_table_history_%s PARTITION OF main_table_history
             FOR VALUES FROM (uuidv7_floor(%L::timestamptz)) TO (uuidv7_floor(%L::timestamptz));',
            part_suffix, curr_date, next_date
        );
        EXECUTE sql_history;

        -- 3. Create standalone GiST index on the history partition
        sql_index := format(
            'CREATE INDEX IF NOT EXISTS idx_main_table_history_%s_range
             ON main_table_history_%s USING GIST (valid_range);',
            part_suffix, part_suffix
        );
        EXECUTE sql_index;
    END LOOP;
END;
$$;

-- Example usage: Provision partitions covering all of 2026
CALL create_monthly_partitions('2026-01-01', 12);
```

Step 4: Targeted Cohort Anonymization & Vacuuming

When an old monthly cohort (e.g., January 2026) reaches its data retention limit, you can anonymize it and vacuum only that single ~40–80 GB partition rather than scanning or locking the 5 TB monolith.

```sql
-- 1. Scrub all revisions belonging to entities created in January 2026
UPDATE main_table_data
SET some_data = 'XXX'
WHERE uuid >= uuidv7_floor('2026-01-01 00:00:00+00'::timestamptz)
  AND uuid <  uuidv7_floor('2026-02-01 00:00:00+00'::timestamptz)
  AND some_data IS DISTINCT FROM 'XXX';

-- 2. Mark anchor as anonymized
UPDATE main_table_anchor
SET anonymized_at = clock_timestamp()
WHERE uuid >= uuidv7_floor('2026-01-01 00:00:00+00'::timestamptz)
  AND uuid <  uuidv7_floor('2026-02-01 00:00:00+00'::timestamptz)
  AND anonymized_at IS NULL;

-- 3. Reclaim physical disk space and flush dead TOAST chunks for January 2026 only
VACUUM (VERBOSE, ANALYZE) main_table_data_2026_01;

-- (Optional) If compliance requires immediate physical erasure from disk blocks:
-- VACUUM FULL main_table_data_2026_01;
```
