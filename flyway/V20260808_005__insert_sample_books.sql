DO $$
DECLARE
    -- 1. Configuration Parameters
    p_book_count integer := 400000;
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
        'Author ' || seq AS author,
        seq AS pub_year,
        'Genre ' || seq AS genre,
        CASE
            WHEN seq <= v_del_old_count THEN 'DEL_OLD'
            WHEN seq <= v_del_old_count + v_del_new_count THEN 'DEL_NEW'
            ELSE 'ACTIVE'
        END AS status
    FROM generate_series(1, p_book_count) AS seq;

    -- 4a. INSERT ANCHORS
    INSERT INTO books_anchor (uuid)
    SELECT uuid FROM tmp_book_bases;

    -- 4b. INSERT REVISION 1 (All books: Created D+13 days ago, closed D+8 days ago)
    -- This guarantees every book has at least one historical record older than the threshold
    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    SELECT
        uuid,
        1,
        title || ' (Draft)',
        author || ' (Draft)',
        pub_year,
        genre || ' (Draft)',
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 13),
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 8)
    FROM tmp_book_bases;

    -- 5. INSERT REVISION 2 (All books: Created D+8 days ago, closed D+3 days ago)
    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    SELECT
        uuid,
        2,
        title || ' (Review)',
        author || ' (Review)',
        pub_year,
        genre || ' (Review)',
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 8),
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 3)
    FROM tmp_book_bases;

    -- 6. INSERT REVISION 3 (Created D+3 days ago, closed based on their target status)
    INSERT INTO books (uuid, revision, title, author, pub_year, genre, revision_from, revision_to)
    SELECT
        uuid,
        3,
        title,
        author,
        pub_year,
        genre,
        CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 3),
        CASE status
            WHEN 'ACTIVE' THEN 'infinity'::timestamp with time zone  -- Stays active forever
            WHEN 'DEL_OLD' THEN CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days + 1)  -- Deleted BEFORE the threshold (e.g., 8 days ago if D=7)
            WHEN 'DEL_NEW' THEN CURRENT_TIMESTAMP - make_interval(days => p_housekeeping_days - 2)  -- Deleted AFTER the threshold (e.g., 2 days ago if D=7)
        END
    FROM tmp_book_bases;

    RAISE NOTICE 'Database initialization complete!';
END;
$$;
