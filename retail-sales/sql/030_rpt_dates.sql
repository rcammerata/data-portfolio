/* The calendar Power BI uses: whole years, from the 'calendar_from' setting to the end of this
   year, so time intelligence (year to date, same period last year) always has complete years. */
CREATE VIEW rpt.dim_date
AS
SELECT
    d.date_key,
    d.calendar_date,
    d.calendar_year,
    d.quarter_label,
    d.month_number,
    d.month_name,
    d.month_short,
    d.year_month,
    d.month_start,
    d.day_of_month,
    d.day_of_week,
    d.day_name,
    d.day_short,
    d.is_weekend,
    d.iso_week,
    d.week_start,
    d.season
FROM dw.dim_date AS d
CROSS APPLY (
    SELECT COALESCE(MAX(TRY_CONVERT(date, s.setting_value)), DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1)) AS first_day
    FROM dw.setting AS s
    WHERE s.setting_key = 'calendar_from'
) AS cfg
WHERE d.calendar_date >= DATEFROMPARTS(YEAR(cfg.first_day), 1, 1)
  AND d.calendar_date <= DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 12, 31);
GO
