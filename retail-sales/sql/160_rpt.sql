/* Reporting views: what Power BI imports, plus two analysis views that show the SQL side
   (year-over-year with a self-join, shares with window functions, rankings with RANK/NTILE). */

CREATE VIEW rpt.dim_county
AS
SELECT
    c.county_key,
    c.county_name,
    p.population,
    p.population_year
FROM dw.dim_county AS c
OUTER APPLY (
    SELECT TOP (1) cp.population, cp.population_year
    FROM dw.county_population AS cp
    WHERE cp.county_key = c.county_key
    ORDER BY cp.population_year DESC
) AS p;
GO

CREATE VIEW rpt.dim_store
AS
SELECT
    s.store_key,
    s.store_number,
    s.store_name,
    CASE WHEN s.city IS NULL THEN s.store_name ELSE CONCAT(s.store_name, N' (', s.city, N')') END AS store_label,
    s.address,
    s.city,
    s.zip_code,
    c.county_name,
    s.latitude,
    s.longitude,
    s.first_sale_date,
    s.last_sale_date
FROM dw.dim_store AS s
JOIN dw.dim_county AS c ON c.county_key = s.county_key;
GO

CREATE VIEW rpt.dim_vendor
AS
SELECT v.vendor_key, v.vendor_number, v.vendor_name
FROM dw.dim_vendor AS v;
GO

CREATE VIEW rpt.dim_category
AS
SELECT c.category_key, c.category_number, c.category_name, c.category_group
FROM dw.dim_category AS c;
GO

CREATE VIEW rpt.dim_item
AS
SELECT
    i.item_key,
    i.item_number,
    i.item_description,
    i.pack,
    i.bottle_volume_ml,
    CASE
        WHEN i.bottle_volume_ml IS NULL THEN N'Unknown size'
        WHEN i.bottle_volume_ml >= 1000 THEN CONCAT(CONVERT(decimal(5, 2), i.bottle_volume_ml / 1000.0), N' L')
        ELSE CONCAT(i.bottle_volume_ml, N' ml')
    END AS bottle_size,
    c.category_name,
    c.category_group,
    v.vendor_name,
    i.last_bottle_retail
FROM dw.dim_item AS i
JOIN dw.dim_category AS c ON c.category_key = i.category_key
JOIN dw.dim_vendor AS v ON v.vendor_key = i.vendor_key;
GO

/* Sales lines from the 'report_from' setting on (Power BI doesn't need all the history the
   database keeps). The invoice number is left out: it is unique per row and would only make
   the Power BI model bigger. */
CREATE VIEW rpt.fact_sales
AS
SELECT
    DATEFROMPARTS(f.date_key / 10000, f.date_key / 100 % 100, f.date_key % 100) AS calendar_date,
    f.store_key,
    f.item_key,
    f.vendor_key,
    f.category_key,
    f.county_key,
    f.bottles_sold,
    f.sale_dollars,
    f.volume_liters,
    CONVERT(decimal(12, 2), f.bottles_sold * f.state_bottle_cost) AS state_cost_dollars,
    CONVERT(decimal(12, 2), f.sale_dollars - f.bottles_sold * f.state_bottle_cost) AS gross_margin_dollars
FROM dw.fact_sales AS f
CROSS APPLY (
    SELECT COALESCE(MAX(TRY_CONVERT(date, s.setting_value)), DATEFROMPARTS(YEAR(SYSUTCDATETIME()) - 3, 1, 1)) AS report_from
    FROM dw.setting AS s
    WHERE s.setting_key = 'report_from'
) AS cfg
WHERE f.date_key >= YEAR(cfg.report_from) * 10000 + MONTH(cfg.report_from) * 100 + DAY(cfg.report_from);
GO

/* Monthly sales per category group with year-over-year change (self-join on the same month a
   year earlier, so missing months can't shift the comparison) and each group's share of the month. */
CREATE VIEW rpt.monthly_category_sales
AS
WITH monthly AS
(
    SELECT
        DATEFROMPARTS(f.date_key / 10000, f.date_key / 100 % 100, 1) AS month_start,
        c.category_group,
        SUM(f.sale_dollars) AS sales_dollars,
        SUM(f.bottles_sold) AS bottles_sold,
        SUM(f.volume_liters) AS volume_liters
    FROM dw.fact_sales AS f
    JOIN dw.dim_category AS c ON c.category_key = f.category_key
    GROUP BY DATEFROMPARTS(f.date_key / 10000, f.date_key / 100 % 100, 1), c.category_group
)
SELECT
    m.month_start,
    m.category_group,
    m.sales_dollars,
    m.bottles_sold,
    m.volume_liters,
    p.sales_dollars AS sales_dollars_prior_year,
    CONVERT(decimal(9, 4), (m.sales_dollars - p.sales_dollars) / NULLIF(p.sales_dollars, 0)) AS yoy_change,
    CONVERT(decimal(9, 4), m.sales_dollars / NULLIF(SUM(m.sales_dollars) OVER (PARTITION BY m.month_start), 0)) AS share_of_month
FROM monthly AS m
LEFT JOIN monthly AS p
    ON p.category_group = m.category_group
   AND p.month_start = DATEADD(year, -1, m.month_start);
GO

/* Store scorecard for the last 12 loaded months vs the 12 before: rank within its county and
   sales quartile across the state. */
CREATE VIEW rpt.store_scorecard
AS
WITH bounds AS
(
    SELECT
        DATEADD(month, -11, MAX(l.load_month)) AS cur_from,
        EOMONTH(MAX(l.load_month)) AS cur_to,
        DATEADD(month, -23, MAX(l.load_month)) AS prev_from,
        EOMONTH(DATEADD(month, -12, MAX(l.load_month))) AS prev_to
    FROM dw.load_log AS l
),
store_sales AS
(
    SELECT
        f.store_key,
        SUM(CASE WHEN dd.calendar_date BETWEEN b.cur_from AND b.cur_to THEN f.sale_dollars ELSE 0 END) AS sales_12m,
        SUM(CASE WHEN dd.calendar_date BETWEEN b.prev_from AND b.prev_to THEN f.sale_dollars ELSE 0 END) AS sales_prior_12m
    FROM dw.fact_sales AS f
    JOIN dw.dim_date AS dd ON dd.date_key = f.date_key
    CROSS JOIN bounds AS b
    WHERE dd.calendar_date BETWEEN b.prev_from AND b.cur_to
    GROUP BY f.store_key
)
SELECT
    s.store_key,
    st.store_label,
    c.county_name,
    s.sales_12m,
    s.sales_prior_12m,
    CONVERT(decimal(9, 4), (s.sales_12m - s.sales_prior_12m) / NULLIF(s.sales_prior_12m, 0)) AS yoy_change,
    RANK() OVER (PARTITION BY c.county_name ORDER BY s.sales_12m DESC) AS rank_in_county,
    NTILE(4) OVER (ORDER BY s.sales_12m DESC) AS sales_quartile
FROM store_sales AS s
JOIN rpt.dim_store AS st ON st.store_key = s.store_key
JOIN dw.dim_county AS c ON c.county_name = st.county_name
WHERE s.sales_12m > 0;
GO
