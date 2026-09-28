-- =====================================================================
-- 01_load.sql
-- Step 1: create the retail_sales table and verify the load.
-- Each query is tagged with "-- name: <id>" so the notebook can run
-- them individually. In the VS Code PostgreSQL extension: run create_table,
-- load the CSV with \copy (see below), then run the check queries.
-- =====================================================================

-- name: create_table
-- IF NOT EXISTS: rerunning this whole file never wipes loaded data.
-- To truly start over, run by hand: DROP TABLE retail_sales;
CREATE TABLE IF NOT EXISTS retail_sales (
    sales_month       date    NOT NULL,
    naics_code        text,             -- text, not int: some codes are "4411, 4412"
    kind_of_business  text    NOT NULL,
    reason_for_null   text,             -- 'Not Available' or 'Supressed' when sales is null
    sales             numeric(12,2),    -- millions of USD, not seasonally adjusted
    PRIMARY KEY (kind_of_business, sales_month)  -- also serves PARTITION BY / ORDER BY
);

-- LOAD THE DATA (not run by this file).
-- After create_table has run, load the CSV from a terminal in the project folder
-- with psql's client-side \copy (your user reads the file, so no permission issues):
--
--   psql -h localhost -U jake -d retail -c "\copy retail_sales FROM 'data/us_retail_sales.csv' WITH (FORMAT csv, HEADER true)"
--
-- Expected output: COPY 22620
-- The notebook does the same thing with COPY FROM STDIN, which also works on Azure.

-- name: check_row_count
-- Expect 22,620 rows, 65 categories, 348 months (1992-01 to 2020-12)
SELECT COUNT(*)                          AS total_rows,
       COUNT(DISTINCT kind_of_business)  AS categories,
       COUNT(DISTINCT sales_month)       AS months,
       MIN(sales_month)                  AS first_month,
       MAX(sales_month)                  AS last_month
FROM retail_sales;

-- name: check_nulls
-- Expect 492 'Not Available' + 102 'Supressed' = 594 null sales
SELECT COALESCE(reason_for_null, '(has value)') AS reason,
       COUNT(*)                                 AS n_rows,
       COUNT(sales)                             AS n_with_sales
FROM retail_sales
GROUP BY 1
ORDER BY 2 DESC;

-- name: check_null_categories
-- Which categories have gaps, and when. Categories chosen for analysis
-- should not appear here (or only outside the analysis window).
SELECT kind_of_business,
       COUNT(*)          AS null_months,
       MIN(sales_month)  AS first_null,
       MAX(sales_month)  AS last_null
FROM retail_sales
WHERE sales IS NULL
GROUP BY kind_of_business
ORDER BY null_months DESC;

-- name: check_candidates
-- Completeness of the five proposed categories: expect 348 months, 0 nulls each
SELECT kind_of_business,
       COUNT(*)                                   AS months,
       COUNT(*) FILTER (WHERE sales IS NULL)      AS null_months,
       ROUND(SUM(sales) / 1000, 1)                AS total_sales_bn
FROM retail_sales
WHERE kind_of_business IN (
    'Electronic shopping and mail-order houses',
    'Department stores',
    'Book stores',
    'Warehouse clubs and superstores',
    'Gasoline stations'
)
GROUP BY kind_of_business
ORDER BY total_sales_bn DESC;
