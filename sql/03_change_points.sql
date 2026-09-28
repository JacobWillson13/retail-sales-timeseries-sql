-- =====================================================================
-- 03_change_points.sql
-- Step 3: detect points where each category's sales trajectory changes.
-- Three methods, all built on the 12-month moving average (ma_12) or
-- year-over-year change (yoy_pct) from v_monthly_metrics, so seasonal
-- spikes never register as change points:
--   A. Moving-average crossover : ma_12 crosses ma_36 (trend turns)
--   B. Local slope reversal     : rolling 24-month regression slope of
--                                 ma_12 changes sign and stays changed
--   C. Standard-deviation shock : monthly YoY growth sits >= 3 standard
--                                 deviations from its trailing 36-month mean
-- The notebook adds a fourth, formal check (PELT from the ruptures library).
-- =====================================================================

-- name: create_view_signals
-- One row per category per month with every signal the detectors need.
CREATE OR REPLACE VIEW v_change_signals AS
WITH base AS (
    SELECT kind_of_business,
           sales_month,
           sales,
           ma_12,
           yoy_pct,
           ROW_NUMBER() OVER (PARTITION BY kind_of_business ORDER BY sales_month) AS t
    FROM v_monthly_metrics
)
SELECT
    kind_of_business,
    sales_month,
    sales,
    ma_12,

    -- A. 36-month moving average: the slow line for the crossover test
    CASE WHEN COUNT(sales) OVER w36 = 36 THEN AVG(sales) OVER w36 END            AS ma_36,

    -- B. Local slope: least-squares slope of ma_12 over the last 24 months,
    --    expressed as % of the current level per year (comparable across sizes)
    CASE WHEN COUNT(ma_12) OVER w24 = 24
         THEN ROUND(100 * 12 * (REGR_SLOPE(ma_12, t) OVER w24)::numeric / ma_12, 2)
    END                                                                          AS trend_pct_yr,

    -- C. YoY growth vs its own recent history (prior 36 months, current excluded)
    yoy_pct,
    AVG(yoy_pct)    OVER prior36                                                 AS yoy_mean_36,
    STDDEV(yoy_pct) OVER prior36                                                 AS yoy_sd_36,
    CASE WHEN COUNT(yoy_pct) OVER prior36 = 36
         THEN ROUND((yoy_pct - AVG(yoy_pct) OVER prior36)
                    / NULLIF(STDDEV(yoy_pct) OVER prior36, 0), 2)
    END                                                                          AS yoy_z
FROM base
WINDOW
    w36     AS (PARTITION BY kind_of_business ORDER BY sales_month
                ROWS BETWEEN 35 PRECEDING AND CURRENT ROW),
    w24     AS (PARTITION BY kind_of_business ORDER BY sales_month
                ROWS BETWEEN 23 PRECEDING AND CURRENT ROW),
    prior36 AS (PARTITION BY kind_of_business ORDER BY sales_month
                ROWS BETWEEN 36 PRECEDING AND 1 PRECEDING);

-- name: create_view_change_points
-- All detected change points from the three methods, one row each.
CREATE OR REPLACE VIEW v_change_points AS
WITH flags AS (
    SELECT *,
           -- A. which side of the slow average the fast one is on
           SIGN(ma_12 - ma_36)                                             AS cross_side,
           LAG(SIGN(ma_12 - ma_36)) OVER w                                 AS cross_side_prev,
           -- B. slope direction now, last month, and over the next 6 months
           SIGN(trend_pct_yr)                                              AS slope_sign,
           LAG(SIGN(trend_pct_yr)) OVER w                                  AS slope_sign_prev,
           MIN(SIGN(trend_pct_yr)) OVER next6                              AS slope_min_next6,
           MAX(SIGN(trend_pct_yr)) OVER next6                              AS slope_max_next6,
           COUNT(trend_pct_yr)     OVER next6                              AS slope_n_next6
    FROM v_change_signals
    WINDOW w     AS (PARTITION BY kind_of_business ORDER BY sales_month),
           next6 AS (PARTITION BY kind_of_business ORDER BY sales_month
                     ROWS BETWEEN CURRENT ROW AND 5 FOLLOWING)
),
crossover AS (
    SELECT kind_of_business, sales_month,
           'A. MA crossover'::text AS method,
           CASE WHEN cross_side < 0 THEN 'down' ELSE 'up' END AS direction,
           'ma_12 crossed ' || CASE WHEN cross_side < 0 THEN 'below' ELSE 'above' END
               || ' ma_36' AS detail
    FROM flags
    WHERE cross_side <> cross_side_prev AND cross_side <> 0 AND cross_side_prev <> 0
),
slope AS (
    -- a sign change only counts if the new direction holds for 6 months
    SELECT kind_of_business, sales_month,
           'B. Slope reversal',
           CASE WHEN slope_sign < 0 THEN 'down' ELSE 'up' END,
           '24-mo trend slope turned ' || CASE WHEN slope_sign < 0 THEN 'negative' ELSE 'positive' END
    FROM flags
    WHERE slope_sign <> slope_sign_prev
      AND slope_sign <> 0
      AND slope_min_next6 = slope_max_next6
      AND slope_n_next6 = 6
),
shock_months AS (
    SELECT kind_of_business, sales_month, yoy_pct, yoy_z,
           -- gaps-and-islands: consecutive flagged months share the same grp
           sales_month - (ROW_NUMBER() OVER (PARTITION BY kind_of_business, SIGN(yoy_z)
                                             ORDER BY sales_month) * INTERVAL '1 month') AS grp
    FROM v_change_signals
    WHERE ABS(yoy_z) >= 3
),
shock AS (
    SELECT kind_of_business, MIN(sales_month),
           'C. YoY shock (|z|>=3)',
           CASE WHEN AVG(yoy_z) < 0 THEN 'down' ELSE 'up' END,
           COUNT(*) || ' mo, YoY ' || ROUND(AVG(yoy_pct), 1) || '%, peak |z| '
               || ROUND(MAX(ABS(yoy_z)), 1)
    FROM shock_months
    GROUP BY kind_of_business, grp
)
SELECT * FROM crossover
UNION ALL SELECT * FROM slope
UNION ALL SELECT * FROM shock;

-- name: change_points_all
-- Every detected change point, by category and date.
SELECT kind_of_business, sales_month, method, direction, detail
FROM v_change_points
ORDER BY kind_of_business, sales_month, method;

-- name: change_points_count
-- How many change points each method found per category.
SELECT kind_of_business,
       COUNT(*) FILTER (WHERE method LIKE 'A.%') AS crossover,
       COUNT(*) FILTER (WHERE method LIKE 'B.%') AS slope_reversal,
       COUNT(*) FILTER (WHERE method LIKE 'C.%') AS yoy_shock,
       COUNT(*)                                  AS total
FROM v_change_points
GROUP BY kind_of_business
ORDER BY total DESC;

-- name: change_points_confirmed
-- Change-point EVENTS confirmed by at least two different methods within
-- 12 months, in the same direction. One row per event (dated by its first
-- signal). These are the ones to trust; a single-method, single-month flag
-- is often noise (calendar effects, one-off promotions).
WITH cp AS (
    SELECT *,
           -- start a new event unless a same-direction signal fired in the prior 12 months
           CASE WHEN LAG(sales_month) OVER (PARTITION BY kind_of_business, direction
                                            ORDER BY sales_month)
                     >= sales_month - INTERVAL '12 months'
                THEN 0 ELSE 1 END AS new_event
    FROM v_change_points
),
events AS (
    SELECT *,
           SUM(new_event) OVER (PARTITION BY kind_of_business, direction
                                ORDER BY sales_month) AS event_id
    FROM cp
)
SELECT kind_of_business,
       MIN(sales_month)                                     AS event_start,
       MAX(sales_month)                                     AS last_signal,
       direction,
       COUNT(DISTINCT method)                               AS methods_agreeing,
       STRING_AGG(DISTINCT LEFT(method, 1), ' + ')          AS methods
FROM events
GROUP BY kind_of_business, direction, event_id
HAVING COUNT(DISTINCT method) >= 2
ORDER BY kind_of_business, event_start;

-- name: trend_by_era
-- Local slope (trend growth, % per year) averaged over economic eras.
-- Shows slowdowns that never flip sign, e.g. Warehouse clubs decelerating.
SELECT kind_of_business,
       ROUND(AVG(trend_pct_yr) FILTER (WHERE sales_month BETWEEN '1994-01-01' AND '2000-12-01'), 1) AS "1994-2000",
       ROUND(AVG(trend_pct_yr) FILTER (WHERE sales_month BETWEEN '2001-01-01' AND '2007-12-01'), 1) AS "2001-2007",
       ROUND(AVG(trend_pct_yr) FILTER (WHERE sales_month BETWEEN '2008-01-01' AND '2010-12-01'), 1) AS "2008-2010",
       ROUND(AVG(trend_pct_yr) FILTER (WHERE sales_month BETWEEN '2011-01-01' AND '2019-12-01'), 1) AS "2011-2019",
       ROUND(AVG(trend_pct_yr) FILTER (WHERE sales_month BETWEEN '2020-01-01' AND '2020-12-01'), 1) AS "2020"
FROM v_change_signals
GROUP BY kind_of_business
ORDER BY "2011-2019" DESC;
