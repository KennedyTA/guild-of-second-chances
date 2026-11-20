# The Guild of Second Chances
*(and poor decisions)*

A character builder and live table screen for a Wednesday evening tabletop game.

- `index.html` is the whole site, served by GitHub Pages.
- `schema.sql` sets up the Supabase database. Tables sit in a private schema; the page only calls a small set of functions.
- Character data and art live in Supabase, never in this repository.
- `update3.sql` and `update4.sql` are later database updates, run once each in the Supabase SQL editor. Update 4 adds solo missions: short branching stories a player plays on their own link, with dice on the page, to earn a perk. The DM loads them as a JSON file on the Missions tab.
