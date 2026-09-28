-- =====================================================================
-- 05_extended.sql
-- Step 5: extended analysis beyond the core assignment.
--   5.1  Share of total retail          (category vs the whole market)
--   5.2  E-commerce vs department stores (the substitution crossover)
--   5.3  Holiday concentration over time (is the season shifting?)
--   5.4  Drawdowns and recessions        (depth and recovery by shock)
--   5.5  COVID-19 month by month         (2020 YoY for the five)
--   5.6  COVID winners and losers        (all industry categories)
--   5.7  Long-run growth leaderboard     (all industry categories)
--   5.8  Co-movement and market beta     (correlations, cyclicality)
--   5.9  Volatility regimes              (rolling SD of YoY growth)
--   5.10 Calendar (trading-day) effects  (weekend-day composition)
-- Aggregate rows (totals, GAFO, "excl" rollups) are the rows with a NULL
-- naics_code; they are excluded from the all-category rankings and used
-- only as the market benchmark ("Retail sales, total").
-- =====================================================================


-- ---------------------------------------------------------------------
-- 5.1 Share of total retail
-- ---------------------------------------------------------------------

-- name: share_of_retail
-- Each category's annual sales as % of "Retail sales, total"
-- (retail only, excludes food services).
WITH total AS (
    SELECT EXTRACT(YEAR FROM sales_month)::int AS sales_year, SUM(sales) AS total_sales
    FROM retail_sales
    WHERE kind_of_business = 'Retail sales, total'
    GROUP BY 1
)
SELECT y.kind_of_business,
       y.sales_year,
       y.year_sales,
       t.total_sales,
       ROUND(100 * y.year_sales / t.total_sales, 2)                            AS pct_of_retail,
       -- change in share vs prior year, in percentage points
       ROUND(100 * y.year_sales / t.total_sales
             - LAG(100 * y.year_sales / t.total_sales)
                   OVER (PARTITION BY y.kind_of_business ORDER BY y.sales_year), 2) AS share_change_pp
FROM v_yearly y
JOIN total t USING (sales_year)
ORDER BY y.kind_of_business, y.sales_year;

-- name: share_summary
-- Share in 1992, 2000, 2010, 2019, 2020 and the total share gained or lost.
WITH total AS (
    SELECT EXTRACT(YEAR FROM sales_month)::int AS sales_year, SUM(sales) AS total_sales
    FROM retail_sales
    WHERE kind_of_business = 'Retail sales, total'
    GROUP BY 1
),
s AS (
    SELECT y.kind_of_business, y.sales_year, 100 * y.year_sales / t.total_sales AS pct
    FROM v_yearly y JOIN total t USING (sales_year)
)
SELECT kind_of_business,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 1992), 2) AS share_1992,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 2000), 2) AS share_2000,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 2010), 2) AS share_2010,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 2019), 2) AS share_2019,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 2020), 2) AS share_2020,
       ROUND(MAX(pct) FILTER (WHERE sales_year = 2020)
           - MAX(pct) FILTER (WHERE sales_year = 1992), 2)  AS change_1992_2020_pp
FROM s
GROUP BY kind_of_business
ORDER BY change_1992_2020_pp DESC;

-- name: market_growth_vs_category
-- Total retail growth vs each category: who outgrew the market?
WITH total AS (
    SELECT EXTRACT(YEAR FROM sales_month)::int AS sales_year, SUM(sales) AS total_sales
    FROM retail_sales
    WHERE kind_of_business = 'Retail sales, total'
    GROUP BY 1
)
SELECT 'Retail sales, total (market)' AS series,
       ROUND(100 * (POWER(MAX(total_sales) FILTER (WHERE sales_year = 2019)
                        / MAX(total_sales) FILTER (WHERE sales_year = 1992), 1.0 / 27) - 1), 2) AS cagr_92_19_pct
FROM total
UNION ALL
SELECT kind_of_business,
       ROUND(100 * (POWER(MAX(year_sales) FILTER (WHERE sales_year = 2019)
                        / MAX(year_sales) FILTER (WHERE sales_year = 1992), 1.0 / 27) - 1), 2)
FROM v_yearly
GROUP BY kind_of_business
ORDER BY cagr_92_19_pct DESC;


-- ---------------------------------------------------------------------
-- 5.2 E-commerce vs department stores
-- ---------------------------------------------------------------------

-- name: ecom_vs_dept_annual
-- Annual ratio of e-commerce to department store sales, and the first
-- year e-commerce was larger.
WITH pair AS (
    SELECT sales_year,
           MAX(year_sales) FILTER (WHERE kind_of_business = 'Electronic shopping and mail-order houses') AS ecom,
           MAX(year_sales) FILTER (WHERE kind_of_business = 'Department stores')                         AS dept
    FROM v_yearly
    GROUP BY sales_year
)
SELECT sales_year,
       ecom,
       dept,
       ROUND(ecom / dept, 3)                                      AS ecom_to_dept_ratio,
       ecom - dept                                                AS gap_musd,
       CASE WHEN ecom > dept
             AND LAG(ecom > dept) OVER (ORDER BY sales_year) IS NOT TRUE
            THEN 'crossover' END                                  AS event
FROM pair
ORDER BY sales_year;

-- name: ecom_vs_dept_monthly_firsts
-- First month e-commerce beat department stores, and the first December
-- (the department stores' strongest month) it did.
WITH m AS (
    SELECT sales_month,
           EXTRACT(MONTH FROM sales_month) AS month_num,
           MAX(sales) FILTER (WHERE kind_of_business = 'Electronic shopping and mail-order houses') AS ecom,
           MAX(sales) FILTER (WHERE kind_of_business = 'Department stores')                         AS dept
    FROM v_monthly_metrics
    GROUP BY sales_month
)
SELECT 'First month e-commerce > department stores' AS milestone,
       MIN(sales_month) AS sales_month
FROM m WHERE ecom > dept
UNION ALL
SELECT 'First December e-commerce > department stores',
       MIN(sales_month)
FROM m WHERE ecom > dept AND month_num = 12
UNION ALL
SELECT 'Last month department stores > e-commerce',
       MAX(sales_month)
FROM m WHERE dept > ecom;


-- ---------------------------------------------------------------------
-- 5.3 Holiday concentration over time
-- ---------------------------------------------------------------------

-- name: holiday_share_by_year
-- November and December share of each year's sales, per category.
SELECT kind_of_business,
       sales_year,
       SUM(pct_of_year) FILTER (WHERE month_num = 11)        AS nov_pct,
       SUM(pct_of_year) FILTER (WHERE month_num = 12)        AS dec_pct,
       SUM(pct_of_year) FILTER (WHERE month_num IN (11, 12)) AS nov_dec_pct
FROM v_monthly_metrics
GROUP BY kind_of_business, sales_year
ORDER BY kind_of_business, sales_year;

-- name: holiday_share_trend
-- Trend in holiday concentration 1992-2019: regression slope of the
-- Nov and Dec shares on year, in percentage points per decade.
WITH h AS (
    SELECT kind_of_business, sales_year,
           SUM(pct_of_year) FILTER (WHERE month_num = 11) AS nov_pct,
           SUM(pct_of_year) FILTER (WHERE month_num = 12) AS dec_pct
    FROM v_monthly_metrics
    WHERE sales_year <= 2019
    GROUP BY kind_of_business, sales_year
)
SELECT kind_of_business,
       ROUND(AVG(dec_pct) FILTER (WHERE sales_year BETWEEN 1992 AND 1996), 2)  AS dec_pct_1992_96,
       ROUND(AVG(dec_pct) FILTER (WHERE sales_year BETWEEN 2015 AND 2019), 2)  AS dec_pct_2015_19,
       ROUND((10 * REGR_SLOPE(dec_pct, sales_year))::numeric, 2)                AS dec_pp_per_decade,
       ROUND((10 * REGR_SLOPE(nov_pct, sales_year))::numeric, 2)                AS nov_pp_per_decade,
       ROUND((REGR_R2(dec_pct, sales_year))::numeric, 2)                        AS r2_dec
FROM h
GROUP BY kind_of_business
ORDER BY dec_pp_per_decade;

-- name: seasonal_amplitude
-- Peak-month / trough-month ratio each year: how "spiky" the year is.
SELECT kind_of_business,
       sales_year,
       ROUND(MAX(sales) / MIN(sales), 3) AS peak_to_trough_ratio,
       ROUND(100 * STDDEV(sales) / AVG(sales), 2) AS monthly_cv_pct
FROM v_monthly_metrics
GROUP BY kind_of_business, sales_year
ORDER BY kind_of_business, sales_year;


-- ---------------------------------------------------------------------
-- 5.4 Drawdowns and recessions
-- ---------------------------------------------------------------------

-- name: create_view_drawdown
-- Drawdown = how far the 12-month MA sits below its all-time high so far.
-- Running peak via MAX() OVER (... UNBOUNDED PRECEDING ...).
CREATE OR REPLACE VIEW v_drawdown AS
SELECT kind_of_business,
       sales_month,
       ma_12,
       MAX(ma_12) OVER (PARTITION BY kind_of_business ORDER BY sales_month
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)       AS running_peak,
       ROUND(100 * (ma_12 / MAX(ma_12) OVER (PARTITION BY kind_of_business ORDER BY sales_month
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) - 1), 2) AS drawdown_pct
FROM v_monthly_metrics
WHERE ma_12 IS NOT NULL;

-- name: max_drawdown
-- Deepest drawdown per category and when it happened.
SELECT DISTINCT ON (kind_of_business)
       kind_of_business,
       sales_month      AS trough_month,
       drawdown_pct     AS max_drawdown_pct
FROM v_drawdown
ORDER BY kind_of_business, drawdown_pct;

-- name: recession_impact
-- For each NBER recession: 12-month MA at the recession start, its low
-- within the following 36 months, and the first month it regained the
-- starting level (NULL = not recovered by Dec 2020).
WITH recessions(recession, r_start, r_end) AS (
    VALUES ('2001 dot-com',     DATE '2001-03-01', DATE '2001-11-01'),
           ('2008-09 Great Recession', DATE '2007-12-01', DATE '2009-06-01'),
           ('2020 COVID-19',    DATE '2020-02-01', DATE '2020-04-01')
),
start_level AS (
    SELECT r.recession, r.r_start, d.kind_of_business, d.ma_12 AS level_at_start
    FROM recessions r
    JOIN v_drawdown d ON d.sales_month = r.r_start
),
trough AS (
    SELECT DISTINCT ON (s.recession, s.kind_of_business)
           s.recession, s.kind_of_business, d.sales_month AS trough_month, d.ma_12 AS trough_level
    FROM start_level s
    JOIN v_drawdown d
      ON d.kind_of_business = s.kind_of_business
     AND d.sales_month BETWEEN s.r_start AND s.r_start + INTERVAL '36 months'
    ORDER BY s.recession, s.kind_of_business, d.ma_12
),
recovery AS (
    SELECT t.recession, t.kind_of_business, MIN(d.sales_month) AS recovered_month
    FROM trough t
    JOIN start_level s USING (recession, kind_of_business)
    JOIN v_drawdown d
      ON d.kind_of_business = t.kind_of_business
     AND d.sales_month > t.trough_month
     AND d.ma_12 >= s.level_at_start
    GROUP BY t.recession, t.kind_of_business
)
SELECT s.recession,
       s.kind_of_business,
       ROUND(100 * (t.trough_level / s.level_at_start - 1), 2)                  AS start_to_trough_pct,
       CASE WHEN t.trough_month = s.r_start THEN NULL ELSE t.trough_month END   AS trough_month,
       CASE WHEN t.trough_month = s.r_start            THEN 'no decline'
            WHEN t.trough_month = DATE '2020-12-01'    THEN 'still falling at data end'
            WHEN r.recovered_month IS NULL             THEN 'never regained start level'
            ELSE 'recovered' END                                                AS status,
       CASE WHEN t.trough_month = s.r_start THEN NULL ELSE r.recovered_month END AS recovered_month,
       CASE WHEN t.trough_month = s.r_start THEN NULL ELSE
       (EXTRACT(YEAR FROM AGE(r.recovered_month, s.r_start)) * 12
        + EXTRACT(MONTH FROM AGE(r.recovered_month, s.r_start)))::int END       AS months_start_to_recovery
FROM start_level s
JOIN trough t USING (recession, kind_of_business)
LEFT JOIN recovery r USING (recession, kind_of_business)
ORDER BY s.r_start, start_to_trough_pct;


-- ---------------------------------------------------------------------
-- 5.5 COVID-19 month by month
-- ---------------------------------------------------------------------

-- name: covid_monthly_yoy
-- 2020 YoY % by month for the five categories (pivoted).
SELECT sales_month,
       MAX(yoy_pct) FILTER (WHERE kind_of_business = 'Electronic shopping and mail-order houses') AS ecommerce,
       MAX(yoy_pct) FILTER (WHERE kind_of_business = 'Warehouse clubs and superstores')           AS warehouse,
       MAX(yoy_pct) FILTER (WHERE kind_of_business = 'Gasoline stations')                         AS gasoline,
       MAX(yoy_pct) FILTER (WHERE kind_of_business = 'Department stores')                         AS department,
       MAX(yoy_pct) FILTER (WHERE kind_of_business = 'Book stores')                               AS books
FROM v_monthly_metrics
WHERE sales_year = 2020
GROUP BY sales_month
ORDER BY sales_month;

-- name: covid_phases
-- Average YoY by pandemic phase: pre (Jan-Feb), lockdown (Mar-May),
-- reopening (Jun-Dec).
SELECT kind_of_business,
       ROUND(AVG(yoy_pct) FILTER (WHERE month_num BETWEEN 1 AND 2), 1)  AS pre_jan_feb,
       ROUND(AVG(yoy_pct) FILTER (WHERE month_num BETWEEN 3 AND 5), 1)  AS lockdown_mar_may,
       ROUND(AVG(yoy_pct) FILTER (WHERE month_num BETWEEN 6 AND 12), 1) AS reopening_jun_dec,
       MIN(yoy_pct)                                                     AS worst_month_yoy,
       MAX(yoy_pct)                                                     AS best_month_yoy
FROM v_monthly_metrics
WHERE sales_year = 2020
GROUP BY kind_of_business
ORDER BY lockdown_mar_may;


-- ---------------------------------------------------------------------
-- 5.6 COVID winners and losers across all industry categories
-- ---------------------------------------------------------------------

-- name: covid_all_categories
-- 2020 vs 2019 for every industry category with 12 reported months in
-- both years. naics_level = digits in the code (3 = broad, 6 = narrow).
WITH yr AS (
    SELECT kind_of_business, naics_code,
           EXTRACT(YEAR FROM sales_month)::int AS sales_year,
           SUM(sales) AS year_sales, COUNT(sales) AS n
    FROM retail_sales
    WHERE naics_code IS NOT NULL
      AND EXTRACT(YEAR FROM sales_month) IN (2019, 2020)
    GROUP BY 1, 2, 3
),
p AS (
    SELECT kind_of_business, naics_code,
           MAX(year_sales) FILTER (WHERE sales_year = 2019) AS s2019,
           MAX(year_sales) FILTER (WHERE sales_year = 2020) AS s2020
    FROM yr
    GROUP BY 1, 2
    HAVING MIN(n) = 12 AND COUNT(*) = 2
)
SELECT kind_of_business,
       naics_code,
       LENGTH(SPLIT_PART(naics_code, ',', 1))                  AS naics_level,
       s2019, s2020,
       ROUND(100 * (s2020 / s2019 - 1), 1)                     AS change_pct,
       RANK() OVER (ORDER BY s2020 / s2019 DESC)               AS rank_best_to_worst,
       kind_of_business IN ('Electronic shopping and mail-order houses', 'Department stores',
                            'Book stores', 'Warehouse clubs and superstores',
                            'Gasoline stations')              AS in_analysis
FROM p
ORDER BY change_pct DESC;


-- ---------------------------------------------------------------------
-- 5.7 Long-run growth leaderboard across all industry categories
-- ---------------------------------------------------------------------

-- name: growth_leaderboard
-- CAGR 1992-2019 for every industry category complete in both years,
-- ranked, with percentile rank (1.0 = fastest growing).
WITH yr AS (
    SELECT kind_of_business, naics_code,
           EXTRACT(YEAR FROM sales_month)::int AS sales_year,
           SUM(sales) AS year_sales, COUNT(sales) AS n
    FROM retail_sales
    WHERE naics_code IS NOT NULL
      AND EXTRACT(YEAR FROM sales_month) IN (1992, 2019)
    GROUP BY 1, 2, 3
),
p AS (
    SELECT kind_of_business, naics_code,
           MAX(year_sales) FILTER (WHERE sales_year = 1992) AS s1992,
           MAX(year_sales) FILTER (WHERE sales_year = 2019) AS s2019
    FROM yr
    GROUP BY 1, 2
    HAVING MIN(n) = 12 AND COUNT(*) = 2
)
SELECT kind_of_business,
       LENGTH(SPLIT_PART(naics_code, ',', 1))                                  AS naics_level,
       s1992, s2019,
       ROUND(100 * (POWER(s2019 / s1992, 1.0 / 27) - 1), 2)                    AS cagr_pct,
       RANK() OVER (ORDER BY s2019 / s1992 DESC)                               AS rank,
       ROUND((PERCENT_RANK() OVER (ORDER BY s2019 / s1992))::numeric, 2)      AS pct_rank,
       kind_of_business IN ('Electronic shopping and mail-order houses', 'Department stores',
                            'Book stores', 'Warehouse clubs and superstores',
                            'Gasoline stations')                              AS in_analysis
FROM p
ORDER BY cagr_pct DESC;


-- ---------------------------------------------------------------------
-- 5.8 Co-movement and market beta
-- ---------------------------------------------------------------------

-- name: yoy_correlation_matrix
-- Pearson correlation of monthly YoY growth between every pair of
-- categories, 1993-2019 (COVID excluded so one year cannot dominate).
SELECT a.kind_of_business                                 AS category_a,
       b.kind_of_business                                 AS category_b,
       ROUND((CORR(a.yoy_pct, b.yoy_pct))::numeric, 3)    AS corr_yoy,
       COUNT(*)                                           AS n_months
FROM v_monthly_metrics a
JOIN v_monthly_metrics b
  ON b.sales_month = a.sales_month
WHERE a.sales_year BETWEEN 1993 AND 2019
  AND a.yoy_pct IS NOT NULL AND b.yoy_pct IS NOT NULL
GROUP BY a.kind_of_business, b.kind_of_business
ORDER BY a.kind_of_business, b.kind_of_business;

-- name: market_beta
-- Cyclicality: regress each category's YoY on total-retail YoY.
-- beta > 1 = amplifies the market's swings; beta < 1 = defensive;
-- beta < 0 = moves against the market. 1993-2019.
WITH total AS (
    SELECT sales_month,
           100 * (sales / LAG(sales, 12) OVER (ORDER BY sales_month) - 1) AS mkt_yoy
    FROM retail_sales
    WHERE kind_of_business = 'Retail sales, total'
),
ex_gas AS (
    -- market excluding gasoline, so gas prices do not drive the benchmark
    SELECT t.sales_month,
           t.sales - g.sales AS sales
    FROM retail_sales t
    JOIN retail_sales g
      ON g.sales_month = t.sales_month AND g.kind_of_business = 'Gasoline stations'
    WHERE t.kind_of_business = 'Retail sales, total'
),
ex_gas_yoy AS (
    SELECT sales_month, 100 * (sales / LAG(sales, 12) OVER (ORDER BY sales_month) - 1) AS mkt_ex_gas_yoy
    FROM ex_gas
)
SELECT m.kind_of_business,
       ROUND((REGR_SLOPE(m.yoy_pct, t.mkt_yoy))::numeric, 2)            AS beta_vs_total,
       ROUND((CORR(m.yoy_pct, t.mkt_yoy))::numeric, 3)                  AS corr_vs_total,
       ROUND((REGR_SLOPE(m.yoy_pct, e.mkt_ex_gas_yoy))::numeric, 2)     AS beta_vs_ex_gas,
       ROUND((CORR(m.yoy_pct, e.mkt_ex_gas_yoy))::numeric, 3)           AS corr_vs_ex_gas
FROM v_monthly_metrics m
JOIN total      t USING (sales_month)
JOIN ex_gas_yoy e USING (sales_month)
WHERE m.sales_year BETWEEN 1993 AND 2019
GROUP BY m.kind_of_business
ORDER BY beta_vs_total DESC;


-- ---------------------------------------------------------------------
-- 5.9 Volatility regimes
-- ---------------------------------------------------------------------

-- name: rolling_volatility
-- Rolling 36-month standard deviation of YoY growth (percentage points).
SELECT kind_of_business,
       sales_month,
       CASE WHEN COUNT(yoy_pct) OVER w = 36
            THEN ROUND(STDDEV(yoy_pct) OVER w, 2) END AS yoy_sd_36m
FROM v_monthly_metrics
WINDOW w AS (PARTITION BY kind_of_business ORDER BY sales_month
             ROWS BETWEEN 35 PRECEDING AND CURRENT ROW)
ORDER BY kind_of_business, sales_month;

-- name: volatility_by_era
-- Standard deviation of monthly YoY growth by era.
SELECT kind_of_business,
       ROUND(STDDEV(yoy_pct) FILTER (WHERE sales_year BETWEEN 1993 AND 2000), 2) AS "1993-2000",
       ROUND(STDDEV(yoy_pct) FILTER (WHERE sales_year BETWEEN 2001 AND 2007), 2) AS "2001-2007",
       ROUND(STDDEV(yoy_pct) FILTER (WHERE sales_year BETWEEN 2008 AND 2010), 2) AS "2008-2010",
       ROUND(STDDEV(yoy_pct) FILTER (WHERE sales_year BETWEEN 2011 AND 2019), 2) AS "2011-2019",
       ROUND(STDDEV(yoy_pct) FILTER (WHERE sales_year = 2020), 2)                AS "2020"
FROM v_monthly_metrics
GROUP BY kind_of_business
ORDER BY "2011-2019" DESC;


-- ---------------------------------------------------------------------
-- 5.10 Calendar (trading-day) effects
-- ---------------------------------------------------------------------

-- name: create_view_calendar
-- Day-of-week composition of every month, built from generate_series.
-- The data is NOT seasonally or trading-day adjusted, so a month with an
-- extra Saturday can look better or worse than the same month last year
-- for reasons that have nothing to do with demand.
CREATE OR REPLACE VIEW v_calendar AS
WITH days AS (
    SELECT d::date AS d
    FROM generate_series('1992-01-01'::date, '2020-12-31'::date, INTERVAL '1 day') AS d
),
m AS (
    SELECT DATE_TRUNC('month', d)::date                            AS sales_month,
           COUNT(*)                                                AS n_days,
           COUNT(*) FILTER (WHERE EXTRACT(ISODOW FROM d) IN (6, 7)) AS weekend_days,
           COUNT(*) FILTER (WHERE EXTRACT(ISODOW FROM d) = 6)      AS saturdays
    FROM days
    GROUP BY 1
)
SELECT *,
       weekend_days - LAG(weekend_days, 12) OVER (ORDER BY sales_month) AS weekend_days_vs_ly,
       saturdays    - LAG(saturdays, 12)    OVER (ORDER BY sales_month) AS saturdays_vs_ly
FROM m;

-- name: calendar_effect
-- Does an extra weekend day (vs the same month last year) push YoY growth
-- up or down? YoY residual = monthly YoY minus its centered 13-month
-- average (removes the trend, keeps month-to-month noise). 1993-2019.
WITH x AS (
    SELECT v.kind_of_business,
           v.sales_month,
           v.yoy_pct - AVG(v.yoy_pct) OVER (PARTITION BY v.kind_of_business ORDER BY v.sales_month
                                            ROWS BETWEEN 6 PRECEDING AND 6 FOLLOWING) AS yoy_resid,
           c.weekend_days_vs_ly,
           c.saturdays_vs_ly
    FROM v_monthly_metrics v
    JOIN v_calendar c USING (sales_month)
)
SELECT kind_of_business,
       ROUND((CORR(yoy_resid, weekend_days_vs_ly))::numeric, 3)        AS corr_weekend_days,
       ROUND((REGR_SLOPE(yoy_resid, weekend_days_vs_ly))::numeric, 2)  AS yoy_pp_per_extra_weekend_day,
       ROUND((CORR(yoy_resid, saturdays_vs_ly))::numeric, 3)           AS corr_saturdays,
       COUNT(*)                                                        AS n_months
FROM x
WHERE sales_month BETWEEN '1993-01-01' AND '2019-12-01'
  AND weekend_days_vs_ly IS NOT NULL
GROUP BY kind_of_business
ORDER BY corr_weekend_days;

-- name: calendar_by_weekend_delta
-- Average YoY residual grouped by weekend-day difference vs last year
-- (-2 to +2), per category: the effect in plain numbers.
WITH x AS (
    SELECT v.kind_of_business,
           v.sales_month,
           v.yoy_pct - AVG(v.yoy_pct) OVER (PARTITION BY v.kind_of_business ORDER BY v.sales_month
                                            ROWS BETWEEN 6 PRECEDING AND 6 FOLLOWING) AS yoy_resid,
           c.weekend_days_vs_ly
    FROM v_monthly_metrics v
    JOIN v_calendar c USING (sales_month)
)
SELECT kind_of_business,
       weekend_days_vs_ly,
       COUNT(*)                         AS n_months,
       ROUND(AVG(yoy_resid), 2)         AS avg_yoy_resid_pp
FROM x
WHERE sales_month BETWEEN '1993-01-01' AND '2019-12-01'
  AND weekend_days_vs_ly IS NOT NULL
GROUP BY kind_of_business, weekend_days_vs_ly
ORDER BY kind_of_business, weekend_days_vs_ly;
