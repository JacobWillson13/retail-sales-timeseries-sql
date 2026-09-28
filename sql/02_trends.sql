-- =====================================================================
-- 02_trends.sql
-- Step 2: monthly and yearly trends for five categories using window
-- functions. Every metric is computed "beside" each row, so the monthly
-- detail is never collapsed.
-- =====================================================================

-- name: create_view_monthly
-- One row per category per month, with every trend metric attached.
-- Saved as a VIEW so steps 3 and 4 can query it directly.
-- CREATE OR REPLACE (not DROP + CREATE): step 3's view depends on this one,
-- so a DROP would fail once step 3 exists. Safe to rerun.
CREATE OR REPLACE VIEW v_monthly_metrics AS
WITH base AS (
    SELECT kind_of_business,
           sales_month,
           EXTRACT(YEAR  FROM sales_month)::int AS sales_year,
           EXTRACT(MONTH FROM sales_month)::int AS month_num,
           sales
    FROM retail_sales
    WHERE kind_of_business IN (
        'Electronic shopping and mail-order houses',
        'Department stores',
        'Book stores',
        'Warehouse clubs and superstores',
        'Gasoline stations'
    )
)
SELECT
    kind_of_business,
    sales_month,
    sales_year,
    month_num,
    sales,

    -- Running total since 1992 (cumulative lifetime sales)
    SUM(sales) OVER (PARTITION BY kind_of_business
                     ORDER BY sales_month
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS running_total,

    -- Year-to-date running total (resets every January)
    SUM(sales) OVER (PARTITION BY kind_of_business, sales_year
                     ORDER BY sales_month
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)   AS ytd_total,

    -- Full-year total repeated on every month of that year (no collapse)
    SUM(sales) OVER (PARTITION BY kind_of_business, sales_year)          AS year_total,

    -- 12-month trailing moving average (removes seasonality)
    CASE WHEN COUNT(sales) OVER w12 = 12
         THEN AVG(sales) OVER w12 END                                    AS ma_12,

    -- 3-month trailing moving average (short-term smoothing)
    CASE WHEN COUNT(sales) OVER w3 = 3
         THEN AVG(sales) OVER w3 END                                     AS ma_3,

    -- Same month last year, and year-over-year % change
    LAG(sales, 12) OVER (PARTITION BY kind_of_business
                         ORDER BY sales_month)                           AS sales_ly,
    ROUND(100.0 * (sales / NULLIF(LAG(sales, 12) OVER (PARTITION BY kind_of_business
                                                       ORDER BY sales_month), 0) - 1), 2)
                                                                         AS yoy_pct,

    -- Share of the year's sales that fell in this month (seasonality)
    ROUND(100.0 * sales / SUM(sales) OVER (PARTITION BY kind_of_business, sales_year), 2)
                                                                         AS pct_of_year
FROM base
WINDOW
    w12 AS (PARTITION BY kind_of_business ORDER BY sales_month
            ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
    w3  AS (PARTITION BY kind_of_business ORDER BY sales_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW);

-- name: example_book_stores
-- Walkthrough example: see every metric side by side for one category.
SELECT sales_month, sales, running_total, ytd_total, year_total,
       ROUND(ma_12, 1) AS ma_12, ROUND(ma_3, 1) AS ma_3,
       sales_ly, yoy_pct, pct_of_year
FROM v_monthly_metrics
WHERE kind_of_business = 'Book stores'
  AND sales_month BETWEEN '2018-10-01' AND '2019-03-01'
ORDER BY sales_month;

-- name: yearly_totals
-- Yearly totals per category (this one DOES collapse to one row per year,
-- because a yearly chart needs one point per year), then window functions
-- run on top of the grouped result for YoY growth and indexing.
WITH yearly AS (
    SELECT kind_of_business,
           sales_year,
           SUM(sales) AS year_sales
    FROM v_monthly_metrics
    GROUP BY kind_of_business, sales_year
)
SELECT kind_of_business,
       sales_year,
       year_sales,
       ROUND(100.0 * (year_sales / LAG(year_sales) OVER w - 1), 1)       AS yoy_pct,
       -- Index vs 1992 = 100, so categories of very different size share one scale
       ROUND(100.0 * year_sales / FIRST_VALUE(year_sales) OVER w, 1)     AS index_1992,
       -- How far below the category's all-time peak year
       ROUND(100.0 * (year_sales / MAX(year_sales) OVER (PARTITION BY kind_of_business) - 1), 1)
                                                                         AS pct_from_peak
FROM yearly
WINDOW w AS (PARTITION BY kind_of_business ORDER BY sales_year)
ORDER BY kind_of_business, sales_year;

-- name: category_summary
-- One line per category: size, growth, peak, volatility.
WITH yearly AS (
    SELECT kind_of_business, sales_year, SUM(sales) AS year_sales
    FROM v_monthly_metrics
    GROUP BY kind_of_business, sales_year
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY kind_of_business ORDER BY year_sales DESC) AS rk
    FROM yearly
)
SELECT y.kind_of_business,
       ROUND(MAX(year_sales) FILTER (WHERE sales_year = 1992) / 1000, 1)   AS sales_1992_bn,
       ROUND(MAX(year_sales) FILTER (WHERE sales_year = 2019) / 1000, 1)   AS sales_2019_bn,
       ROUND(MAX(year_sales) FILTER (WHERE sales_year = 2020) / 1000, 1)   AS sales_2020_bn,
       -- Compound annual growth rate 1992 to 2019 (pre-COVID)
       ROUND(100.0 * (POWER(MAX(year_sales) FILTER (WHERE sales_year = 2019)
                          / MAX(year_sales) FILTER (WHERE sales_year = 1992), 1.0 / 27) - 1), 2)
                                                                           AS cagr_92_19_pct,
       MAX(sales_year) FILTER (WHERE rk = 1)                               AS peak_year,
       ROUND(100.0 * (MAX(year_sales) FILTER (WHERE sales_year = 2020)
                    / MAX(year_sales) FILTER (WHERE sales_year = 2019) - 1), 1)
                                                                           AS covid_2020_pct
FROM ranked y
GROUP BY y.kind_of_business
ORDER BY cagr_92_19_pct DESC;

-- name: seasonality
-- Average share of annual sales by calendar month, 1992-2019
-- (8.33% = perfectly flat year). Pivoted so categories are columns.
SELECT month_num,
       ROUND(AVG(pct_of_year) FILTER (WHERE kind_of_business = 'Electronic shopping and mail-order houses'), 2) AS ecommerce,
       ROUND(AVG(pct_of_year) FILTER (WHERE kind_of_business = 'Department stores'), 2)               AS department,
       ROUND(AVG(pct_of_year) FILTER (WHERE kind_of_business = 'Book stores'), 2)                     AS books,
       ROUND(AVG(pct_of_year) FILTER (WHERE kind_of_business = 'Warehouse clubs and superstores'), 2) AS warehouse,
       ROUND(AVG(pct_of_year) FILTER (WHERE kind_of_business = 'Gasoline stations'), 2)               AS gasoline
FROM v_monthly_metrics
WHERE sales_year <= 2019
GROUP BY month_num
ORDER BY month_num;
