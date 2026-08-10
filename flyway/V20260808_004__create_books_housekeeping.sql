-- create function
CREATE OR REPLACE FUNCTION api.housekeeping_books_history(
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
        ALTER TABLE books_history ADD CONSTRAINT books_history__hk_time_boundary_new CHECK (revision_to <= %1$L::timestamp with time zone) NOT VALID;
        ALTER TABLE books_history ADD CONSTRAINT books_history__hk_range_boundary_new CHECK (revision_range <@ tstzrange(NULL, %1$L::timestamp with time zone, ''[)'')) NOT VALID;
    ', v_threshold);

    -- validate new constraints
    ALTER TABLE books_history VALIDATE CONSTRAINT books_history__hk_time_boundary_new;
    ALTER TABLE books_history VALIDATE CONSTRAINT books_history__hk_range_boundary_new;

    -- drop old constraints
    ALTER TABLE books_history DROP CONSTRAINT IF EXISTS books_history__hk_time_boundary;
    ALTER TABLE books_history DROP CONSTRAINT IF EXISTS books_history__hk_range_boundary;

    -- rename new constraints
    ALTER TABLE books_history RENAME CONSTRAINT books_history__hk_time_boundary_new TO books_history__hk_time_boundary;
    ALTER TABLE books_history RENAME CONSTRAINT books_history__hk_range_boundary_new TO books_history__hk_range_boundary;

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
    INSERT INTO books_history (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    SELECT uuid, revision, title, author, pub_year, genre, revision_from, revision_to
    FROM moved_rows
    -- sort for BRIN index
    ORDER BY revision_to ASC, revision_from ASC;

    GET DIAGNOSTICS v_rows_moved = ROW_COUNT;

    RAISE LOG 'Housekeeping complete: Moved % rows to cold storage.', v_rows_moved;

    RETURN v_rows_moved;
END;
$$;
