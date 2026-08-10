# Temporalna baza danych

## Luźnie wiązanie danych (weak-reference)

Luźnie wiązanie danych pozwala na przenoszenie danych między tabelami z zerwaniem spójności między nimi. Z jednej strony jest to niepożądane zachowanie lecz z drugiej bardzo upraszcza niektóre rozwiązania, np. podział danych na gorące (hot) i ziemne (cold) bez użycia [natywnych mechanizmów bazy danych jak partycjonowanie](https://www.postgresql.org/docs/current/ddl-partitioning.html). Partycjonowanie narzuca dużo ograniczeń jeśli chodzi struktury danych i w przypadku danych temporalnych niweluje twarde wiązania pomiędzy danymi:

- kolumna po której się partycjonuje musi występować we wszystkich PRIMARY KEY oraz indeksach UNIQUE.
- brak globalnego wymuszenia ograniczeń np. sprawdzenia nachodzenia zakresów pomiędzy partycjami (potrzebny dodatkowy mechanizm sprawdzenia spójności cross-partycje)

> Przykłady zakładają użycie PostgreSQL 18+. Dla wcześniejszych wersji należy używać `EXCLUDE USING gist`

Weźmy dla przykładu tabele `books`:

```sql
CREATE TABLE books
(
    -- uni-temporal model
    uuid uuid NOT NULL DEFAULT gen_random_uuid(),
    revision integer NOT NULL,
    revision_from timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP::timestamp with time zone,
    revision_to timestamp with time zone NOT NULL 'infinity'::timestamp with time zone,
    revision_range tstzrange GENERATED ALWAYS AS (tstzrange(revision_from, revision_to, '[)')) STORED,

    -- business data
    title text NOT NULL DEFAULT '',

    -- constraints
    CONSTRAINT books_c_uuid PRIMARY KEY (uuid, revision_range WITHOUT OVERLAPS), -- PSQL 18+
    CONSTRAINT books_c_unique_revisions UNIQUE (uuid, revision),
    CONSTRAINT books_c_no_empty_revisions CHECK (NOT isempty(revision_range)),
    CONSTRAINT books_c_check_revision_number CHECK (revision >= 1)
);
```

Próbując wprowadzić natywny mechanizm deklaratywnego partycjonowania _psujemy_ ograniczenia bazy danych.

```sql
CREATE TABLE books
(
    (...)
    CONSTRAINT books_c_uuid PRIMARY KEY (uuid, revision_to, revision_range WITHOUT OVERLAPS), -- wymaga dodania revision_to
    CONSTRAINT books_c_unique_revisions UNIQUE (uuid, revision, revision_to), -- wymaga dodania revision_to
    (...)
) PARTITION BY RANGE (revision_to);

-- hot data
-- dlaczego MAXVALUE? patrz: https://www.postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-PARTITION
CREATE TABLE books_hot PARTITION OF books
    FOR VALUES FROM ('infinity') TO (MAXVALUE);

-- cold data
CREATE TABLE books_cold PARTITION OF books
    FOR VALUES FROM (MINVALUE) TO ('infinity');
```

Zamiast natywnego partycjonowania można utworzyć `API` na dane i _wymusić_ pewne zachowania. Dla przykładu wybrano mechanizm dziedziczenia.

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- hot data
CREATE TABLE books
(
    uuid uuid NOT NULL DEFAULT gen_random_uuid(),
    revision integer NOT NULL,
    revision_from timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP::timestamp with time zone,
    revision_to timestamp with time zone NOT NULL DEFAULT 'infinity'::timestamp with time zone,
    revision_range tstzrange GENERATED ALWAYS AS (tstzrange(revision_from, revision_to, '[)')) STORED,

    title text NOT NULL DEFAULT '',
    description text NULL,
    
    CONSTRAINT books__pk PRIMARY KEY (uuid, revision_range WITHOUT OVERLAPS), -- PSQL 18+
    
    CONSTRAINT books__unique_revisions UNIQUE (uuid, revision),
    CONSTRAINT books__no_empty_revisions CHECK (NOT isempty(revision_range)),
    CONSTRAINT books__check_revision_number CHECK (revision >= 1)
);

-- dodanie indeksu dla aktywnych rekordow
CREATE INDEX books__active_uuids_idx
    ON books USING btree(uuid ASC NULLS LAST)
    WHERE revision_to = 'infinity'::timestamp with time zone;
-- dodanie indeksu BRIN
CREATE INDEX books__revision_from_brin_idx
    ON public.books USING brin(revision_from);

-- cold data
CREATE TABLE books_cold
(
    CONSTRAINT books_cold__pk PRIMARY KEY (uuid, revision_range WITHOUT OVERLAPS),
    CONSTRAINT books_cold__unique_revisions UNIQUE (uuid, revision),
    CONSTRAINT books_cold__history_only CHECK (revision_to <> 'infinity'),
    CONSTRAINT books_cold__hk_range_boundary CHECK (revision_range <@ tstzrange(NULL, '-infinity', '[)')), -- housekeeping will update this check
    CONSTRAINT books_cold__hk_time_boundary CHECK (revision_to <= '-infinity') -- housekeeping will update this check
) INHERITS (books);

-- dodanie indeksu BRIN - dane będą posortowane
CREATE INDEX books_cold_brin_idx
    ON books_cold USING brin (revision_range) WITH (pages_per_range = 128);

-- pobierz dane ze wszystkich tabel
SELECT * FROM books;

-- pobierz dane tylko z hot data
SELECT * FROM ONLY books;
```

Przykład `API` do modyfikacji danych i wymuszenia spójności danych.

```sql
-- add book
CREATE OR REPLACE FUNCTION add_book (
    p_uuid uuid DEFAULT gen_random_uuid(),
    p_title text
)
RETURNS uuid LANGUAGE plpgsql AS $$
BEGIN
    -- cross table check for unique ID
    IF EXISTS (SELECT 1 FROM books WHERE uuid = p_uuid) THEN
        RAISE EXCEPTION 'Book UUID % already exists.', p_uuid;
    END IF;

    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    VALUES (p_uuid, 1, p_title, CURRENT_TIMESTAMP, 'infinity');

    RETURN p_uuid;
END;
$$;

-- update book
CREATE OR REPLACE FUNCTION update_book (
    p_uuid uuid,
    p_revision integer,
    p_title text
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_locked_revision integer;
    v_locked_revision_to timestamp with time zone;
BEGIN
    SELECT * INTO v_locked_revision, v_locked_revision_to
    FROM record_optimistic_lock('books', p_uuid, p_revision);

    IF v_locked_revision_to = 'infinity' THEN
        UPDATE ONLY books
        SET revision_to = CURRENT_TIMESTAMP
        WHERE uuid = p_uuid AND revision = v_locked_revision;
    END IF;

    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    VALUES (p_uuid, v_locked_revision + 1, p_title, CURRENT_TIMESTAMP, 'infinity');

    RETURN v_locked_revision + 1;
END;
$$;

-- patch book
CREATE OR REPLACE FUNCTION patch_book (
    p_uuid uuid,
    p_revision integer,
    p_patch jsonb
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_old_book books%ROWTYPE;
    v_book books%ROWTYPE;
    v_locked_revision integer;
    v_locked_revision_to timestamp with time zone;
BEGIN
    SELECT * INTO v_locked_revision, v_locked_revision_to
    FROM record_optimistic_lock('books', p_uuid, p_revision);

    SELECT * INTO v_old_book
    FROM books
    WHERE uuid = p_uuid AND revision = v_locked_revision;

    -- prevent fields manipulation
    p_patch := p_patch - '{uuid, revision, revision_from, revision_to, revision_range}'::text[];
    v_book := jsonb_populate_record(v_old_book, p_patch);

    IF v_book IS NOT DISTINCT FROM v_old_book AND v_locked_revision_to = 'infinity' THEN
        RETURN v_locked_revision;
    END IF;

    IF v_locked_revision_to = 'infinity' THEN
        UPDATE ONLY books
        SET revision_to = CURRENT_TIMESTAMP
        WHERE uuid = p_uuid AND revision = v_locked_revision;
    END IF;

    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    VALUES (p_uuid, v_locked_revision + 1, v_book.title, CURRENT_TIMESTAMP, 'infinity');

    RETURN v_locked_revision + 1;
END;
$$;

-- delete book
CREATE OR REPLACE FUNCTION delete_book (
    p_uuid uuid,
    p_revision integer
)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_locked_revision integer;
    v_locked_revision_to timestamp with time zone;
BEGIN
    SELECT * INTO v_locked_revision, v_locked_revision_to
    FROM record_optimistic_lock('books', p_uuid, p_revision);

    IF v_locked_revision_to != 'infinity' THEN
        RAISE NOTICE 'Book UUID % is already deleted.', p_uuid;
        RETURN;
    END IF;

    UPDATE ONLY books
    SET revision_to = CURRENT_TIMESTAMP
    WHERE uuid = p_uuid AND revision = v_locked_revision;
END;
$$;

-- optimistic locking
CREATE OR REPLACE FUNCTION record_optimistic_lock (
    p_table_name regclass,
    p_uuid uuid,
    p_revision integer,
    OUT locked_revision integer,
    OUT locked_revision_to timestamp with time zone
)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('
        SELECT revision, revision_to
        FROM %s
        WHERE uuid = $1
        ORDER BY revision DESC
        LIMIT 1
        FOR UPDATE
    ', p_table_name)
    USING p_uuid
    INTO locked_revision, locked_revision_to;

    IF locked_revision IS NULL THEN
        RAISE EXCEPTION 'Cannot lock: Record with UUID % not found in table %.', p_uuid, p_table_name;
    END IF;

    IF locked_revision != p_revision THEN
        RAISE EXCEPTION 'Optimistic locking failed for UUID % in table %: Expected revision %, but found %',
        p_uuid, p_table_name, p_revision, locked_revision;
    END IF;
END;
$$;
```

Proces przenoszenia danych do `cold tier` (housekeeping).

```sql
CREATE OR REPLACE FUNCTION housekeeping_books_to_cold(
    p_limit integer DEFAULT 100000
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_rows_moved integer;
    v_threshold timestamp with time zone;
BEGIN
    v_threshold := CURRENT_TIMESTAMP - INTERVAL '7 days';

    -- add new more relaxed constraints (as time moves forward)
    EXECUTE format('
        ALTER TABLE books_cold ADD CONSTRAINT books_cold__hk_time_boundary_new CHECK (revision_to <= %1$L::timestamp with time zone) NOT VALID;
        ALTER TABLE books_cold ADD CONSTRAINT books_cold__hk_range_boundary_new CHECK (revision_range <@ tstzrange(NULL, %1$L::timestamp with time zone, ''[)'')) NOT VALID;
    ', v_threshold);
    
    -- validate new constraints
    ALTER TABLE books_cold VALIDATE CONSTRAINT books_cold__hk_time_boundary_new;
    ALTER TABLE books_cold VALIDATE CONSTRAINT books_cold__hk_range_boundary_new;

    -- drop old constraints
    ALTER TABLE books_cold DROP CONSTRAINT IF EXISTS books_cold__hk_time_boundary;
    ALTER TABLE books_cold DROP CONSTRAINT IF EXISTS books_cold__hk_range_boundary;
    
    -- rename new constraints
    ALTER TABLE books_cold RENAME CONSTRAINT books_cold__hk_time_boundary_new TO books_cold__hk_time_boundary;
    ALTER TABLE books_cold RENAME CONSTRAINT books_cold__hk_range_boundary_new TO books_cold__hk_range_boundary;

    WITH candidates AS (
        -- Select the oldest specific rows up to the exact limit
        SELECT uuid AS c_uuid, revision AS c_revision
        FROM ONLY books
        WHERE revision_to <= v_threshold
        ORDER BY revision_to ASC, revision_from ASC
        LIMIT p_limit
        FOR UPDATE -- Safely lock these rows during the transaction
    ),
    moved_rows AS (
        DELETE FROM ONLY books
        USING candidates
        WHERE books.uuid = candidates.c_uuid 
          AND books.revision = candidates.c_revision
        RETURNING *
    )
    INSERT INTO books_cold (uuid, revision, title, revision_from, revision_to)
    SELECT uuid, revision, title, revision_from, revision_to
    FROM moved_rows
    -- sort for BRIN index
    ORDER BY revision_to ASC, revision_from ASC;

    GET DIAGNOSTICS v_rows_moved = ROW_COUNT;
    
    RAISE LOG 'Housekeeping complete: Moved % rows to cold storage.', v_rows_moved;

    RETURN v_rows_moved;
END;
$$;
```

Używając pg_cron można zautomatyzować proces Housekeeping'u w samej bazie danych.

```text
-- install according to docs
-- https://github.com/citusdata/pg_cron#creating-a-cron-job-in-a-different-database
Dockerfile
FROM postgres:18
RUN apt-get update \
    && apt-get -y install postgresql-18-cron \
    && rm -rf /var/lib/apt/lists/*

-- Cron will use 'postgres' database
postgres \
    -c shared_preload_libraries=pg_cron \
    -c cron.database_name=postgres \
    -c cron.use_background_workers=on

-- Run this inside the 'postgres' database
CREATE EXTENSION pg_cron;
```

```sql
-- schedule cron job
SELECT cron.schedule_in_database(
    job_name := 'housekeeping_books_history_10k',
    schedule := '* * * * *',
    command  := 'SELECT api.housekeeping_books_to_cold(10000);',
    database := 'docker'
    username := 'docker'
);
```

Inicjalizacja danymi testowymi.

```sql
DO $$
DECLARE
    -- 1. Configuration Parameters
    p_book_count integer := 100000;
    p_housekeeping_days integer := 7;
    p_delete_pct numeric := 1.0; -- 1%

    -- Internal variables
    v_del_old_count integer;
    v_del_new_count integer;
    v_active_count integer;
BEGIN
    -- 2. Calculate the exact number of books for each state
    -- Half of the deleted books will be older than threshold, half will be newer
    v_del_old_count := (p_book_count * (p_delete_pct / 100.0) / 2)::integer;
    v_del_new_count := (p_book_count * (p_delete_pct / 100.0) / 2)::integer;
    v_active_count := p_book_count - v_del_old_count - v_del_new_count;

    RAISE NOTICE 'Generating % total books (3 revisions each = % rows)...', p_book_count, p_book_count * 3;
    RAISE NOTICE ' - % active books', v_active_count;
    RAISE NOTICE ' - % deleted > % days ago (WILL BE MOVED TO COLD)', v_del_old_count, p_housekeeping_days;
    RAISE NOTICE ' - % deleted <= % days ago (WILL STAY HOT)', v_del_new_count, p_housekeeping_days;

    -- 3. Create a temporary table to hold our base UUIDs and target state
    CREATE TEMP TABLE tmp_book_bases ON COMMIT DROP AS
    SELECT 
        gen_random_uuid() AS uuid,
        'Book Title ' || seq AS title,
        CASE 
            WHEN seq <= v_del_old_count THEN 'DEL_OLD'
            WHEN seq <= v_del_old_count + v_del_new_count THEN 'DEL_NEW'
            ELSE 'ACTIVE'
        END AS status
    FROM generate_series(1, p_book_count) AS seq;

    -- 4. INSERT REVISION 1 (All books: Created D+13 days ago, closed D+8 days ago)
    -- This guarantees every book has at least one historical record older than the threshold
    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    SELECT 
        uuid, 
        1, 
        title || ' (Draft)', 
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 13),
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 8)
    FROM tmp_book_bases;

    -- 5. INSERT REVISION 2 (All books: Created D+8 days ago, closed D+3 days ago)
    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    SELECT 
        uuid, 
        2, 
        title || ' (Review)', 
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 8),
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 3)
    FROM tmp_book_bases;

    -- 6. INSERT REVISION 3 (Created D+3 days ago, closed based on their target status)
    INSERT INTO books (uuid, revision, title, revision_from, revision_to)
    SELECT 
        uuid, 
        3, 
        title, 
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 3),
        CASE status
            -- Stays active forever
            WHEN 'ACTIVE' THEN 'infinity'::timestamp with time zone
            
            -- Deleted BEFORE the threshold (e.g., 8 days ago if D=7)
            WHEN 'DEL_OLD' THEN CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 1)
            
            -- Deleted AFTER the threshold (e.g., 2 days ago if D=7)
            WHEN 'DEL_NEW' THEN CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days - 2)
        END
    FROM tmp_book_bases;

    RAISE NOTICE 'Database initialization complete!';
END;
$$;
```

Sprawdzenie wykoniania CRON

```sql
-- run on postgres database
SELECT * FROM cron.job;
SELECT * FROM cron.job_run_details;
```

Uruchamianie

```bash
# start on foreground
# sample data creation takes about 1 minute
docker compose up

# look for DB logs for cron
[db]      | 2026-08-10 21:33:00.010 UTC [76] LOG:  cron job 1 starting: SELECT api.housekeeping_books_history(1000);
[db]      | 2026-08-10 21:33:00.350 UTC [85] LOG:  Housekeeping complete: Moved 1000 rows to cold storage.

# stop and remove volumes
docker compose down -v
```
