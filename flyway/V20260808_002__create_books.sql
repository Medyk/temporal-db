-- create table
CREATE TABLE IF NOT EXISTS books_anchor
(
    uuid uuid NOT NULL DEFAULT gen_random_uuid(),
    CONSTRAINT books_anchor__pk PRIMARY KEY (uuid)
);

-- create table
CREATE TABLE IF NOT EXISTS books
(
    uuid uuid NOT NULL DEFAULT gen_random_uuid(), -- unique "family" identifier
    revision integer NOT NULL DEFAULT 1,        -- revision number for optimistic locking
    revision_from timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP::timestamp with time zone,  -- timestamp of creation or last revision
    revision_to timestamp with time zone NOT NULL DEFAULT 'infinity'::timestamp with time zone, -- timestamp of next revision or infinity
    -- https://www.postgresql.org/docs/current/range-types.html
    revision_range tstzrange GENERATED ALWAYS AS (tstzrange(revision_from, revision_to, '[)')) STORED,
    revision_range_cc tstzrange GENERATED ALWAYS AS (tstzrange(revision_from, revision_to, '[]')) STORED, -- used for delta queries
    -- entity fields
    title text NOT NULL,                        -- title of the book
    author text NOT NULL,                       -- author of the book
    pub_year integer NOT NULL,                  -- publication year of the book
    genre text NOT NULL,                        -- genre of the book
    -- constraints
    -- https://neon.com/postgresql/18/temporal-constraints
    CONSTRAINT books_anchor__fk FOREIGN KEY (uuid) REFERENCES books_anchor (uuid),
    CONSTRAINT books__pk PRIMARY KEY (uuid, revision_range WITHOUT OVERLAPS), -- no overlapping revisions
    CONSTRAINT books__uq_revisions UNIQUE (uuid, revision),
    CONSTRAINT books__c_no_empty_revisions CHECK (NOT isempty(revision_range)), -- no empty revisions
    CONSTRAINT books__c_revision_positive CHECK (revision >= 1)
);

-- indexes
CREATE INDEX IF NOT EXISTS books__idx_revision_from
    ON books
    USING brin (revision_from);
CREATE INDEX IF NOT EXISTS books__idx_active_records
    ON books
    USING btree (uuid ASC NULLS LAST)
    WHERE revision_to = 'infinity'::timestamp with time zone;
CREATE INDEX IF NOT EXISTS books__idx_revision_range_cc
    ON books
    USING gist (revision_range_cc);


-- create table
CREATE TABLE IF NOT EXISTS books_history
(
    CONSTRAINT books_anchor__fk FOREIGN KEY (uuid) REFERENCES books_anchor (uuid),
    CONSTRAINT books_history__pk PRIMARY KEY (uuid, revision_range WITHOUT OVERLAPS), -- no overlapping revisions
    CONSTRAINT books_history__uq_revisions UNIQUE (uuid, revision),
    CONSTRAINT books_history__c_history_only CHECK (revision_to <> 'infinity'),
    CONSTRAINT books_history__hk_range_boundary CHECK (revision_range <@ tstzrange(NULL, '-infinity', '[)')), -- housekeeping will update this check
    CONSTRAINT books_history__hk_time_boundary CHECK (revision_to <= '-infinity') -- housekeeping will update this check
    ) INHERITS (books);

-- indexes
CREATE INDEX books_history__idx_revision_range
    ON books_history
    USING brin (revision_range)
    WITH (pages_per_range = 128);
CREATE INDEX books_history__idx_revision_range_cc
    ON books_history
    USING brin (revision_range_cc)
    WITH (pages_per_range = 128);
