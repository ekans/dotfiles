-- The BB walkpad plugin's schema (bb-plugin-walkpad/store.ts) with two
-- made-up sessions, times in ms. test_store.py builds a database from it.
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER NOT NULL,
  elapsed_s INTEGER NOT NULL,
  distance_km REAL NOT NULL,
  calories INTEGER NOT NULL,
  max_speed REAL NOT NULL
);
CREATE TABLE samples (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  ts INTEGER NOT NULL,
  speed REAL NOT NULL,
  distance_km REAL NOT NULL,
  calories INTEGER NOT NULL,
  elapsed_s INTEGER NOT NULL
);
INSERT INTO sessions VALUES (1, 1800000000000, 1800000600000, 600, 0.5, 20, 3.0);
INSERT INTO sessions VALUES (2, 1800090000000, 1800090300000, 300, 0.25, 11, 3.5);
INSERT INTO samples VALUES (1, 1800000000000, 3.0, 0.0, 0, 1);
INSERT INTO samples VALUES (1, 1800000001000, 3.0, 0.0, 0, 2);
INSERT INTO samples VALUES (1, 1800000600000, 0.0, 0.5, 20, 600);
INSERT INTO samples VALUES (2, 1800090000000, 3.5, 0.0, 0, 1);
INSERT INTO samples VALUES (2, 1800090300000, 0.0, 0.25, 11, 300);
