-- Rewrite the experience clause of every profile-derived saved search to the rule the
-- SPA now seeds (freehire#3397 follow-up).
--
-- A "Jobs matching my profile" alert is a saved query built by filtersFromProfile. The
-- entry-level bound added in #3414 also ticked experience_include_unspecified, keeping
-- the postings that state no experience at all — most of the catalogue. On the reporter's
-- alert the irrelevant postings it let through were exactly those, and the seeder now
-- leaves that modifier off: a profile whose levels are all intern/junior keeps only the
-- postings that state a bound the candidate can meet. The reporter had already saved
-- their profile after #3414, so changing the seeder alone would leave their stored alert
-- sending those postings until the next profile edit. This file is that one-off bridge.
--
-- Scope and rule:
--   * derived_from_profile rows only. A manually saved search is the user's own query
--     and is never rewritten.
--   * cap 1 when every selected level is intern; cap 2 when the profile selects only
--     intern and/or junior and at least one is junior; no cap otherwise. A missing
--     profile row is treated as "no cap". This mirrors entryExperienceCap in
--     web/src/lib/facetModel.ts.
--   * the query is a URL-encoded filter string, so it is split on '&' — a value cannot
--     contain a raw '&' — and only the two experience params are removed/added. Every
--     other filter survives in order.
--   * a rewrite that would leave a non-empty query empty is skipped: widening a broken
--     derived alert to the whole catalogue is worse than leaving it alone.
--   * updated_at is deliberately untouched. This corrects a derived value; it is not a
--     user edit, and bumping it would reorder every alert in its owner's saved searches.
--
-- Idempotent: the UPDATE is guarded by IS DISTINCT FROM, so a second run writes nothing.
-- saved_searches holds a few thousand rows and the join is on user_profiles.user_id.

WITH target AS (
    SELECT s.id,
           s.query,
           CASE
               WHEN p.seniorities IS NOT NULL
                AND cardinality(p.seniorities) > 0
                AND NOT EXISTS (
                    SELECT 1
                    FROM unnest(p.seniorities) AS lvl(value)
                    WHERE lvl.value NOT IN ('intern', 'junior')
                )
               THEN CASE WHEN 'junior' = ANY (p.seniorities) THEN 2 ELSE 1 END
               ELSE NULL
           END AS cap
    FROM public.saved_searches s
    LEFT JOIN public.user_profiles p ON p.user_id = s.user_id
    WHERE s.derived_from_profile
),
stripped AS (
    SELECT t.id,
           t.query AS original,
           t.cap,
           COALESCE(
               (
                   SELECT string_agg(part, '&' ORDER BY ord)
                   FROM unnest(string_to_array(t.query, '&')) WITH ORDINALITY AS parts(part, ord)
                   WHERE split_part(parts.part, '=', 1)
                         NOT IN ('experience_years_max', 'experience_include_unspecified')
               ),
               ''
           ) AS query
    FROM target t
),
planned AS (
    SELECT id,
           original,
           CASE
               WHEN cap IS NULL THEN query
               WHEN query = '' THEN 'experience_years_max=' || cap
               ELSE query || '&experience_years_max=' || cap
           END AS query
    FROM stripped
)
UPDATE public.saved_searches s
SET query = planned.query
FROM planned
WHERE s.id = planned.id
  AND s.query IS DISTINCT FROM planned.query
  AND NOT (planned.query = '' AND planned.original <> '');
