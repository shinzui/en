-- Commit-ordered grant generations, independent of unrelated database XIDs.
CREATE TABLE en_grant_generation_head
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , generation bigint NOT NULL CHECK (generation >= 0)
  );
INSERT INTO en_grant_generation_head (generation) VALUES (0);

CREATE TABLE en_grant_generation
  ( generation bigint PRIMARY KEY CHECK (generation >= 0)
  , created_xid xid8 NOT NULL UNIQUE
  );
INSERT INTO en_grant_generation (generation, created_xid)
VALUES (0, pg_current_xact_id());

CREATE FUNCTION en_stamp_grant_generation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  next_generation bigint;
BEGIN
  -- An anchor can be touched repeatedly in one transaction; stamp it once.
  IF EXISTS (SELECT 1 FROM en_grant_generation WHERE created_xid = NEW.xid) THEN
    RETURN NULL;
  END IF;
  -- This row lock remains held through commit. A later committer cannot obtain
  -- an earlier generation, even if it allocated its transaction ID first.
  UPDATE en_grant_generation_head
  SET generation = generation + 1
  WHERE singleton
  RETURNING generation INTO next_generation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'grant generation head is missing';
  END IF;
  INSERT INTO en_grant_generation (generation, created_xid)
  VALUES (next_generation, NEW.xid);
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER en_transaction_grant_generation
AFTER INSERT OR UPDATE ON en_transaction
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION en_stamp_grant_generation();
