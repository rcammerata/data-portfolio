/* What gets published on the public portfolio page: hourly and daily summaries only, rounded,
   without the most recent days ('public_delay_days'), and nothing that names a device. */

CREATE VIEW pub.climate_hourly
AS
WITH cfg AS
(
    SELECT
        COALESCE(MAX(CASE WHEN s.setting_key = 'public_delay_days' THEN TRY_CONVERT(int, s.setting_value) END), 3) AS delay_days,
        COALESCE(MAX(CASE WHEN s.setting_key = 'time_zone' THEN s.setting_value END), N'UTC') AS time_zone
    FROM dw.setting AS s
),
bounds AS
(
    SELECT DATEADD(day, -cfg.delay_days,
                   CONVERT(date, (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone)) AS cutoff
    FROM cfg
)
SELECT
    DATETRUNC(hour, c.bucket_start_local) AS hour_start,
    CONVERT(decimal(4, 1), AVG(c.indoor_humidity)) AS indoor_humidity_pct,
    CONVERT(decimal(5, 1), AVG(c.indoor_temp_f)) AS indoor_temp_f,
    CONVERT(decimal(5, 1), AVG(c.outdoor_temp_f)) AS outdoor_temp_f,
    CONVERT(decimal(4, 1), AVG(c.outdoor_humidity)) AS outdoor_humidity_pct,
    CONVERT(decimal(4, 1), AVG(c.outdoor_abs_humidity)) AS outdoor_abs_humidity_gm3,
    CONVERT(decimal(4, 1), AVG(c.target_high)) AS target_max_pct,
    CONVERT(int, ROUND(SUM(c.minutes_on), 0)) AS dehumidifier_minutes
FROM rpt.fact_climate_5min AS c
CROSS JOIN bounds AS b
WHERE c.bucket_start_local < b.cutoff
  AND c.bucket_start_local >= DATEADD(day, -400, b.cutoff)
GROUP BY DATETRUNC(hour, c.bucket_start_local);
GO

CREATE VIEW pub.climate_daily
AS
WITH cfg AS
(
    SELECT
        COALESCE(MAX(CASE WHEN s.setting_key = 'public_delay_days' THEN TRY_CONVERT(int, s.setting_value) END), 3) AS delay_days,
        COALESCE(MAX(CASE WHEN s.setting_key = 'time_zone' THEN s.setting_value END), N'UTC') AS time_zone
    FROM dw.setting AS s
),
bounds AS
(
    SELECT DATEADD(day, -cfg.delay_days,
                   CONVERT(date, (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone)) AS cutoff
    FROM cfg
)
SELECT
    d.calendar_date,
    d.avg_indoor_humidity,
    d.min_indoor_humidity,
    d.max_indoor_humidity,
    d.rolling_7_day_indoor_humidity,
    d.avg_indoor_temp_f,
    d.avg_outdoor_temp_f,
    d.avg_outdoor_abs_humidity,
    d.avg_target_high,
    d.pct_time_at_or_below_target,
    d.runtime_hours,
    d.est_kwh,
    d.dehumidifier_runs,
    d.bucket_full_events
FROM rpt.daily_climate AS d
CROSS JOIN bounds AS b
WHERE d.calendar_date < b.cutoff
  AND d.calendar_date >= DATEADD(day, -400, b.cutoff);
GO
