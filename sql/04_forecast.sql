-- =====================================================================
-- 04_forecast.sql
-- Step 4: three-year forecasts (2021-2023), built entirely in SQL.
--
-- Primary category: Department stores. Every query also runs for the
-- other four categories so the methods can be compared across very
-- different trajectories (steady decline, steady growth, volatile).
--
-- Methods
--   M1 Linear trend       : OLS on annual sales, REGR_SLOPE / REGR_INTERCEPT
--   M2 Log-linear trend   : OLS on LN(annual sales) = constant % change per year
--   M3 Rolling mean, flat : last 12-month moving average held constant
--   M4 Rolling mean + drift: last 12-month MA extended by its recent slope
--   M5 Rebased trend      : M1's slope, restarted from the 2020 actual level
--                           ("no recovery" scenario, vs M1 = "return to trend")
--
-- Default fit window: 2010-2019. Starts after the Great Recession and
-- stops before COVID, so neither shock bends the trend line. 2020 is then
-- a true out-of-sample year: comparing it to the forecast measures the
-- COVID gap. Window choice is tested in forecast_sensitivity.
-- =====================================================================

-- name: create_view_yearly
-- Annual totals per category (full years only).
CREATE OR REPLACE VIEW v_yearly AS
SELECT kind_of_business,
       sales_year,
       SUM(sales)    AS year_sales,
       COUNT(sales)  AS n_months
FROM v_monthly_metrics
GROUP BY kind_of_business, sales_year
HAVING COUNT(sales) = 12;

-- name: trend_fit
-- Fit statistics for M1 and M2 on 2010-2019, per category.
-- REGR_* are ordinary-least-squares aggregates built into Postgres.
WITH train AS (
    SELECT * FROM v_yearly WHERE sales_year BETWEEN 2010 AND 2019
)
SELECT kind_of_business,
       REGR_COUNT(year_sales, sales_year)                                  AS n_years,
       -- M1 linear: $ change per year
       ROUND((REGR_SLOPE(year_sales, sales_year))::numeric, 1)             AS slope_musd_per_yr,
       ROUND((REGR_R2(year_sales, sales_year))::numeric, 3)                AS r2_linear,
       -- standard error of the regression: sqrt(SSE / (n - 2)),
       -- with SSE = Syy - Sxy^2 / Sxx
       ROUND(SQRT((REGR_SYY(year_sales, sales_year)
                   - POWER(REGR_SXY(year_sales, sales_year), 2) / REGR_SXX(year_sales, sales_year))
                  / (REGR_COUNT(year_sales, sales_year) - 2))::numeric, 1) AS se_musd,
       -- M2 log-linear: exp(slope) - 1 = constant annual % change
       ROUND((100 * (EXP(REGR_SLOPE(LN(year_sales), sales_year)) - 1))::numeric, 2)
                                                                           AS pct_change_per_yr,
       ROUND((REGR_R2(LN(year_sales), sales_year))::numeric, 3)            AS r2_log
FROM train
GROUP BY kind_of_business
ORDER BY kind_of_business;

-- name: forecast_annual
-- Annual forecasts 2020-2023 for every category and method.
-- 2020 is out of sample (compare to actual); 2021-2023 is the forecast.
-- M1 carries a 95% prediction interval:
--   yhat +/- t * se * sqrt(1 + 1/n + (x - xbar)^2 / Sxx),  t(0.975, df = 8) = 2.306
WITH train AS (
    SELECT * FROM v_yearly WHERE sales_year BETWEEN 2010 AND 2019
),
fit AS (
    SELECT kind_of_business,
           REGR_COUNT(year_sales, sales_year)       AS n,
           REGR_SLOPE(year_sales, sales_year)       AS b,
           REGR_INTERCEPT(year_sales, sales_year)   AS a,
           REGR_AVGX(year_sales, sales_year)        AS xbar,
           REGR_SXX(year_sales, sales_year)         AS sxx,
           SQRT((REGR_SYY(year_sales, sales_year)
                 - POWER(REGR_SXY(year_sales, sales_year), 2) / REGR_SXX(year_sales, sales_year))
                / (REGR_COUNT(year_sales, sales_year) - 2)) AS se,
           REGR_SLOPE(LN(year_sales), sales_year)       AS b_log,
           REGR_INTERCEPT(LN(year_sales), sales_year)   AS a_log
    FROM train
    GROUP BY kind_of_business
),
ma AS (
    -- rolling-mean anchors: 12-month MA at Dec 2019 and Dec 2017
    SELECT kind_of_business,
           MAX(ma_12) FILTER (WHERE sales_month = '2019-12-01') AS ma_last,
           MAX(ma_12) FILTER (WHERE sales_month = '2017-12-01') AS ma_2y_ago
    FROM v_monthly_metrics
    GROUP BY kind_of_business
),
horizon AS (
    SELECT generate_series(2020, 2023) AS yr
)
SELECT f.kind_of_business,
       h.yr                                                        AS forecast_year,
       ROUND((f.a + f.b * h.yr)::numeric, 0)                       AS m1_linear,
       ROUND((f.a + f.b * h.yr
              - 2.306 * f.se * SQRT(1 + 1.0 / f.n + POWER(h.yr - f.xbar, 2) / f.sxx))::numeric, 0)
                                                                   AS m1_lower_95,
       ROUND((f.a + f.b * h.yr
              + 2.306 * f.se * SQRT(1 + 1.0 / f.n + POWER(h.yr - f.xbar, 2) / f.sxx))::numeric, 0)
                                                                   AS m1_upper_95,
       ROUND(EXP(f.a_log + f.b_log * h.yr)::numeric, 0)            AS m2_log_linear,
       ROUND(12 * m.ma_last, 0)                                    AS m3_flat_ma,
       -- drift = average annual change in the 12-month MA over the last 2 years
       ROUND(12 * (m.ma_last + (h.yr - 2019) * (m.ma_last - m.ma_2y_ago) / 2), 0)
                                                                   AS m4_ma_drift,
       ROUND((y20.year_sales + f.b * (h.yr - 2020))::numeric, 0)   AS m5_rebased,
       y.year_sales                                                AS actual
FROM fit f
JOIN ma m      USING (kind_of_business)
JOIN v_yearly y20
       ON y20.kind_of_business = f.kind_of_business AND y20.sales_year = 2020
CROSS JOIN horizon h
LEFT JOIN v_yearly y
       ON y.kind_of_business = f.kind_of_business AND y.sales_year = h.yr
ORDER BY f.kind_of_business, h.yr;

-- name: forecast_covid_gap
-- How far 2020 actual landed from the 2010-2019 trend (2020 was never
-- used in the fit). Negative gap = sales the pandemic took away vs trend.
WITH fit AS (
    SELECT kind_of_business,
           REGR_SLOPE(year_sales, sales_year)          AS b,
           REGR_INTERCEPT(year_sales, sales_year)      AS a,
           REGR_SLOPE(LN(year_sales), sales_year)      AS b_log,
           REGR_INTERCEPT(LN(year_sales), sales_year)  AS a_log
    FROM v_yearly
    WHERE sales_year BETWEEN 2010 AND 2019
    GROUP BY kind_of_business
),
est AS (
    SELECT f.kind_of_business,
           y.year_sales                    AS actual,
           f.a + f.b * 2020                AS m1,
           EXP(f.a_log + f.b_log * 2020)   AS m2
    FROM fit f
    JOIN v_yearly y ON y.kind_of_business = f.kind_of_business AND y.sales_year = 2020
)
SELECT kind_of_business,
       ROUND(actual, 0)                               AS actual_2020,
       ROUND(m1::numeric, 0)                          AS trend_2020_linear,
       ROUND((100 * (actual / m1 - 1))::numeric, 1)   AS gap_vs_linear_pct,
       ROUND(m2::numeric, 0)                          AS trend_2020_log,
       ROUND((100 * (actual / m2 - 1))::numeric, 1)   AS gap_vs_log_pct
FROM est
ORDER BY gap_vs_linear_pct;

-- name: forecast_monthly
-- Monthly forecast Jan 2021 - Dec 2023 for every category:
-- M1 annual forecast (and its interval) x average monthly share of the
-- year over 2015-2019. Keeps the seasonal shape the trend line lacks.
WITH train AS (
    SELECT * FROM v_yearly WHERE sales_year BETWEEN 2010 AND 2019
),
fit AS (
    SELECT kind_of_business,
           REGR_COUNT(year_sales, sales_year)       AS n,
           REGR_SLOPE(year_sales, sales_year)       AS b,
           REGR_INTERCEPT(year_sales, sales_year)   AS a,
           REGR_AVGX(year_sales, sales_year)        AS xbar,
           REGR_SXX(year_sales, sales_year)         AS sxx,
           SQRT((REGR_SYY(year_sales, sales_year)
                 - POWER(REGR_SXY(year_sales, sales_year), 2) / REGR_SXX(year_sales, sales_year))
                / (REGR_COUNT(year_sales, sales_year) - 2)) AS se
    FROM train
    GROUP BY kind_of_business
),
season AS (
    SELECT kind_of_business, month_num, AVG(pct_of_year) / 100 AS share
    FROM v_monthly_metrics
    WHERE sales_year BETWEEN 2015 AND 2019
    GROUP BY kind_of_business, month_num
),
months AS (
    SELECT generate_series('2021-01-01'::date, '2023-12-01'::date, INTERVAL '1 month')::date AS sales_month
)
SELECT f.kind_of_business,
       m.sales_month,
       ROUND((s.share * (f.a + f.b * EXTRACT(YEAR FROM m.sales_month)))::numeric, 0) AS forecast,
       ROUND((s.share * (f.a + f.b * EXTRACT(YEAR FROM m.sales_month)
              - 2.306 * f.se * SQRT(1 + 1.0 / f.n
                    + POWER(EXTRACT(YEAR FROM m.sales_month) - f.xbar, 2) / f.sxx)))::numeric, 0) AS lower_95,
       ROUND((s.share * (f.a + f.b * EXTRACT(YEAR FROM m.sales_month)
              + 2.306 * f.se * SQRT(1 + 1.0 / f.n
                    + POWER(EXTRACT(YEAR FROM m.sales_month) - f.xbar, 2) / f.sxx)))::numeric, 0) AS upper_95
FROM fit f
CROSS JOIN months m
JOIN season s
  ON s.kind_of_business = f.kind_of_business
 AND s.month_num = EXTRACT(MONTH FROM m.sales_month)
ORDER BY f.kind_of_business, m.sales_month;

-- name: forecast_backtest
-- Honest accuracy check: fit on 2010-2016 only, forecast 2017-2019,
-- compare to what actually happened. MAPE = mean absolute % error.
WITH train AS (
    SELECT * FROM v_yearly WHERE sales_year BETWEEN 2010 AND 2016
),
fit AS (
    SELECT kind_of_business,
           REGR_SLOPE(year_sales, sales_year)          AS b,
           REGR_INTERCEPT(year_sales, sales_year)      AS a,
           REGR_SLOPE(LN(year_sales), sales_year)      AS b_log,
           REGR_INTERCEPT(LN(year_sales), sales_year)  AS a_log
    FROM train
    GROUP BY kind_of_business
),
ma AS (
    SELECT kind_of_business,
           MAX(ma_12) FILTER (WHERE sales_month = '2016-12-01') AS ma_last,
           MAX(ma_12) FILTER (WHERE sales_month = '2014-12-01') AS ma_2y_ago
    FROM v_monthly_metrics
    GROUP BY kind_of_business
),
preds AS (
    SELECT y.kind_of_business, y.sales_year, y.year_sales AS actual,
           f.a + f.b * y.sales_year                                       AS m1,
           EXP(f.a_log + f.b_log * y.sales_year)                          AS m2,
           12 * m.ma_last                                                 AS m3,
           12 * (m.ma_last + (y.sales_year - 2016) * (m.ma_last - m.ma_2y_ago) / 2) AS m4
    FROM v_yearly y
    JOIN fit f USING (kind_of_business)
    JOIN ma  m USING (kind_of_business)
    WHERE y.sales_year BETWEEN 2017 AND 2019
)
SELECT kind_of_business,
       ROUND((100 * AVG(ABS(m1 / actual - 1)))::numeric, 2) AS mape_m1_linear,
       ROUND((100 * AVG(ABS(m2 / actual - 1)))::numeric, 2) AS mape_m2_log,
       ROUND((100 * AVG(ABS(m3 / actual - 1)))::numeric, 2) AS mape_m3_flat_ma,
       ROUND((100 * AVG(ABS(m4 / actual - 1)))::numeric, 2) AS mape_m4_ma_drift
FROM preds
GROUP BY kind_of_business
ORDER BY kind_of_business;

-- name: forecast_backtest_detail
-- Year-by-year backtest predictions next to actuals (for charting).
WITH train AS (
    SELECT * FROM v_yearly WHERE sales_year BETWEEN 2010 AND 2016
),
fit AS (
    SELECT kind_of_business,
           REGR_SLOPE(year_sales, sales_year)          AS b,
           REGR_INTERCEPT(year_sales, sales_year)      AS a,
           REGR_SLOPE(LN(year_sales), sales_year)      AS b_log,
           REGR_INTERCEPT(LN(year_sales), sales_year)  AS a_log
    FROM train
    GROUP BY kind_of_business
),
ma AS (
    SELECT kind_of_business,
           MAX(ma_12) FILTER (WHERE sales_month = '2016-12-01') AS ma_last,
           MAX(ma_12) FILTER (WHERE sales_month = '2014-12-01') AS ma_2y_ago
    FROM v_monthly_metrics
    GROUP BY kind_of_business
)
SELECT y.kind_of_business, y.sales_year, y.year_sales AS actual,
       ROUND((f.a + f.b * y.sales_year)::numeric, 0)                           AS m1_linear,
       ROUND(EXP(f.a_log + f.b_log * y.sales_year)::numeric, 0)                AS m2_log,
       ROUND(12 * m.ma_last, 0)                                                AS m3_flat_ma,
       ROUND(12 * (m.ma_last + (y.sales_year - 2016) * (m.ma_last - m.ma_2y_ago) / 2), 0) AS m4_ma_drift
FROM v_yearly y
JOIN fit f USING (kind_of_business)
JOIN ma  m USING (kind_of_business)
WHERE y.sales_year BETWEEN 2017 AND 2019
ORDER BY y.kind_of_business, y.sales_year;

-- name: forecast_sensitivity
-- How much does the fit window change the answer? Department stores
-- linear trend fitted on five different windows, projected to 2023.
WITH windows(window_name, y0, y1) AS (
    VALUES ('A. 1992-2019 (full, pre-COVID)', 1992, 2019),
           ('B. 2001-2019 (post-peak)',       2001, 2019),
           ('C. 2010-2019 (default)',         2010, 2019),
           ('D. 2015-2019 (recent)',          2015, 2019),
           ('E. 2010-2020 (incl. COVID)',     2010, 2020)
)
SELECT w.window_name,
       ROUND((REGR_SLOPE(y.year_sales, y.sales_year))::numeric, 0)                        AS slope_musd_per_yr,
       ROUND((REGR_R2(y.year_sales, y.sales_year))::numeric, 3)                           AS r2,
       ROUND((REGR_INTERCEPT(y.year_sales, y.sales_year)
              + REGR_SLOPE(y.year_sales, y.sales_year) * 2023)::numeric, 0)               AS forecast_2023_linear,
       ROUND((EXP(REGR_INTERCEPT(LN(y.year_sales), y.sales_year)
              + REGR_SLOPE(LN(y.year_sales), y.sales_year) * 2023))::numeric, 0)          AS forecast_2023_log,
       -- year the linear trend would reach zero (only meaningful for a declining trend)
       CASE WHEN REGR_SLOPE(y.year_sales, y.sales_year) < 0
            THEN FLOOR(-REGR_INTERCEPT(y.year_sales, y.sales_year)
                       / REGR_SLOPE(y.year_sales, y.sales_year))::int END                 AS linear_hits_zero
FROM windows w
JOIN v_yearly y
  ON y.kind_of_business = 'Department stores'
 AND y.sales_year BETWEEN w.y0 AND w.y1
GROUP BY w.window_name
ORDER BY w.window_name;
