/* Published on the public portfolio page. The source data is public already; these are just
   small summaries for the charts. */

CREATE VIEW pub.retail_monthly
AS
SELECT
    m.month_start,
    m.category_group,
    CONVERT(bigint, ROUND(m.sales_dollars, 0)) AS sales_usd,
    m.bottles_sold,
    CONVERT(bigint, ROUND(m.volume_liters, 0)) AS volume_liters,
    m.yoy_change
FROM rpt.monthly_category_sales AS m
WHERE m.month_start <= (SELECT MAX(l.load_month) FROM dw.load_log AS l);
GO

CREATE VIEW pub.retail_top_vendors
AS
WITH bounds AS
(
    SELECT DATEADD(month, -11, MAX(l.load_month)) AS cur_from, EOMONTH(MAX(l.load_month)) AS cur_to
    FROM dw.load_log AS l
),
vendor_sales AS
(
    SELECT v.vendor_name, SUM(f.sale_dollars) AS sales_dollars
    FROM dw.fact_sales AS f
    JOIN dw.dim_date AS dd ON dd.date_key = f.date_key
    JOIN dw.dim_vendor AS v ON v.vendor_key = f.vendor_key
    CROSS JOIN bounds AS b
    WHERE dd.calendar_date BETWEEN b.cur_from AND b.cur_to
    GROUP BY v.vendor_name
)
SELECT TOP (15)
    RANK() OVER (ORDER BY vs.sales_dollars DESC) AS sales_rank,
    vs.vendor_name,
    CONVERT(bigint, ROUND(vs.sales_dollars, 0)) AS sales_usd_12m,
    CONVERT(decimal(5, 2), 100 * vs.sales_dollars / NULLIF(SUM(vs.sales_dollars) OVER (), 0)) AS share_pct
FROM vendor_sales AS vs
ORDER BY vs.sales_dollars DESC;
GO

CREATE VIEW pub.retail_summary
AS
WITH bounds AS
(
    SELECT
        MIN(l.load_month) AS first_month,
        MAX(l.load_month) AS last_month,
        SUM(CONVERT(bigint, l.rows_loaded)) AS rows_loaded
    FROM dw.load_log AS l
),
sales AS
(
    SELECT
        SUM(CASE WHEN dd.calendar_date BETWEEN DATEADD(month, -11, b.last_month) AND EOMONTH(b.last_month)
                 THEN f.sale_dollars ELSE 0 END) AS sales_12m,
        SUM(CASE WHEN dd.calendar_date BETWEEN DATEADD(month, -23, b.last_month) AND EOMONTH(DATEADD(month, -12, b.last_month))
                 THEN f.sale_dollars ELSE 0 END) AS sales_prior_12m,
        COUNT(DISTINCT CASE WHEN dd.calendar_date >= DATEADD(month, -11, b.last_month) THEN f.store_key END) AS active_stores,
        COUNT(DISTINCT CASE WHEN dd.calendar_date >= DATEADD(month, -11, b.last_month) THEN f.item_key END) AS active_items
    FROM dw.fact_sales AS f
    JOIN dw.dim_date AS dd ON dd.date_key = f.date_key
    CROSS JOIN bounds AS b
    WHERE dd.calendar_date >= DATEADD(month, -23, b.last_month)
)
SELECT
    b.first_month,
    b.last_month,
    b.rows_loaded,
    CONVERT(bigint, ROUND(s.sales_12m, 0)) AS sales_usd_12m,
    CONVERT(bigint, ROUND(s.sales_prior_12m, 0)) AS sales_usd_prior_12m,
    CONVERT(decimal(9, 4), (s.sales_12m - s.sales_prior_12m) / NULLIF(s.sales_prior_12m, 0)) AS yoy_change,
    s.active_stores,
    s.active_items
FROM bounds AS b
CROSS JOIN sales AS s;
GO
