-- musset.app's counters: one row per day, kind, version and country. No visitor is recorded, only how many.
--   download  a DMG fetched from the site        update  a DMG fetched by the app's updater (Sparkle)
--   check     the app asking the feed whether there is a new version (about once a day per Mac that runs it)
CREATE TABLE IF NOT EXISTS counts (
  day TEXT NOT NULL, kind TEXT NOT NULL, version TEXT NOT NULL, country TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind, version, country)
);
