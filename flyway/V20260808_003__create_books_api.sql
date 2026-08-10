-- api functions
-- add book
CREATE OR REPLACE FUNCTION api.add_book (
    p_json jsonb,
    p_uuid uuid DEFAULT gen_random_uuid()
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    v_book books%ROWTYPE;
BEGIN
    -- cross table check for unique ID
    IF EXISTS (SELECT 1 FROM books_anchor WHERE uuid = p_uuid) THEN
        RAISE EXCEPTION 'Book UUID % already exists.', p_uuid;
    END IF;

    INSERT INTO books_anchor (uuid)
    VALUES (p_uuid);

    v_book := jsonb_populate_record(v_book, p_json);
    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    VALUES (p_uuid, 1, v_book.title, v_book.author, v_book.pub_year, v_book.genre, CURRENT_TIMESTAMP, 'infinity');

    RETURN p_uuid;
END;
$$;

-- update book
CREATE OR REPLACE FUNCTION api.update_book (
    p_uuid uuid,
    p_revision integer,
    p_json jsonb
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_book books%ROWTYPE;
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

    v_book := jsonb_populate_record(v_book, p_json);
    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    VALUES (p_uuid, v_locked_revision + 1, v_book.title, v_book.author, v_book.pub_year, v_book.genre, CURRENT_TIMESTAMP, 'infinity');

    RETURN v_locked_revision + 1;
END;
$$;

-- patch book
CREATE OR REPLACE FUNCTION api.patch_book (
    p_uuid uuid,
    p_revision integer,
    p_json jsonb
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
    p_json := p_json - '{uuid, revision, revision_from, revision_to, revision_range}'::text[];
    v_book := jsonb_populate_record(v_old_book, p_json);

    IF v_book IS NOT DISTINCT FROM v_old_book AND v_locked_revision_to = 'infinity' THEN
        RETURN v_locked_revision;
    END IF;

    IF v_locked_revision_to = 'infinity' THEN
        UPDATE ONLY books
        SET revision_to = CURRENT_TIMESTAMP
        WHERE uuid = p_uuid AND revision = v_locked_revision;
    END IF;

    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    VALUES (p_uuid, v_locked_revision + 1, v_book.title, v_book.author, v_book.pub_year, v_book.genre, CURRENT_TIMESTAMP, 'infinity');

    RETURN v_locked_revision + 1;
END;
$$;

-- delete book
CREATE OR REPLACE FUNCTION api.delete_book (
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
CREATE OR REPLACE FUNCTION api.record_optimistic_lock (
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