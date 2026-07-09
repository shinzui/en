-- This database's persistent identity.
--
-- Every consistency token embeds a datastore id, and token validation rejects a
-- token whose id does not match the serving datastore. That guard is only worth
-- anything if distinct databases carry distinct ids -- en-server previously
-- hardcoded the same string in every deployment, so two servers pointed at
-- different databases minted mutually acceptable tokens whose embedded snapshots
-- were meaningless in the other database.
--
-- The id is minted by the server on first startup, not here: keeping the
-- migration pure DDL leaves it deterministic and free of any dependency on
-- pgcrypto for gen_random_uuid(). The server inserts a candidate with
-- ON CONFLICT DO NOTHING and then reads back whichever id won, so servers racing
-- on first startup converge rather than fighting.
--
-- The singleton column enforces exactly-one-row at the schema level: the primary
-- key admits one `true`, and the check constraint forbids `false`.
CREATE TABLE en_datastore_metadata
  ( singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton)
  , datastore_id text NOT NULL
  , created_at timestamptz NOT NULL DEFAULT now()
  );
