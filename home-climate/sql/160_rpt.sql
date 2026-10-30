/* Reporting views: what Power BI imports. Local times, friendly units, one row per bucket.
   The indoor sensor reads low: 'indoor_humidity_offset' (5 points) is added here to it and to the
   automation's target band (set on the same scale), so the raw tables keep what the sensor sent.
   They start at 'report_start_local' when it's set (the first hours were incomplete while devices
   were being added); the raw tables keep everything. */

CREATE VIEW rpt.dim_time
AS
SELECT t.time_key, t.hour_24, t.minute_of_hour, t.time_label, t.hour_label, t.part_of_day
FROM dw.dim_time AS t;
GO

/* One row per 5-minute bucket: the readings pivoted into columns (conditional aggregation),
   joined to what the dehumidifier was doing, with the estimated energy use and cost. */
CREATE VIEW rpt.fact_climate_5min
AS
WITH readings AS
(
    SELECT
        f.bucket_start_utc,
        MAX(f.date_key) AS date_key,
        MAX(f.time_key) AS time_key,
        MAX(CASE WHEN m.metric_code = 'indoor_humidity' THEN f.avg_value END) AS indoor_humidity,
        MAX(CASE WHEN m.metric_code = 'indoor_temp_f' THEN f.avg_value END) AS indoor_temp_f,
        MAX(CASE WHEN m.metric_code = 'outdoor_temp_f' THEN f.avg_value END) AS outdoor_temp_f,
        MAX(CASE WHEN m.metric_code = 'outdoor_humidity' THEN f.avg_value END) AS outdoor_humidity,
        MAX(CASE WHEN m.metric_code = 'outdoor_abs_humidity' THEN f.avg_value END) AS outdoor_abs_humidity,
        MAX(CASE WHEN m.metric_code = 'dehumidifier_humidity' THEN f.avg_value END) AS dehumidifier_humidity,
        MAX(CASE WHEN m.metric_code = 'target_low' THEN f.avg_value END) AS target_low,
        MAX(CASE WHEN m.metric_code = 'target_high' THEN f.avg_value END) AS target_high
    FROM dw.fact_reading_5min AS f
    JOIN dw.dim_metric AS m ON m.metric_key = f.metric_key
    GROUP BY f.bucket_start_utc
),
cfg AS
(
    SELECT
        COALESCE(MAX(CASE WHEN s.setting_key = 'time_zone' THEN s.setting_value END), N'UTC') AS time_zone,
        COALESCE(MAX(CASE WHEN s.setting_key = 'dehumidifier_watts' THEN TRY_CONVERT(decimal(9, 2), s.setting_value) END), 380) AS watts,
        COALESCE(MAX(CASE WHEN s.setting_key = 'electricity_usd_per_kwh' THEN TRY_CONVERT(decimal(9, 4), s.setting_value) END), 0.182) AS usd_per_kwh,
        COALESCE(MAX(CASE WHEN s.setting_key = 'indoor_humidity_offset' THEN TRY_CONVERT(decimal(5, 2), s.setting_value) END), 0) AS rh_offset,
        TRY_CONVERT(datetime2(0), MAX(CASE WHEN s.setting_key = 'report_start_local' THEN NULLIF(s.setting_value, N'') END), 126) AS report_start
    FROM dw.setting AS s
)
SELECT
    k.bucket_start_utc,
    CONVERT(datetime2(0), (k.bucket_start_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) AS bucket_start_local,
    dd.calendar_date,
    k.time_key,
    CONVERT(decimal(5, 1), r.indoor_humidity + cfg.rh_offset) AS indoor_humidity,
    CONVERT(decimal(5, 1), r.indoor_temp_f) AS indoor_temp_f,
    CONVERT(decimal(5, 1), r.outdoor_temp_f) AS outdoor_temp_f,
    CONVERT(decimal(5, 1), r.outdoor_humidity) AS outdoor_humidity,
    -- when the sensor has no value (Oct 26 evening, while the weather entity was renamed): the same
    -- formula Home Assistant uses, from the outdoor temperature and humidity
    CONVERT(decimal(5, 1), COALESCE(r.outdoor_abs_humidity,
        6.112 * EXP(17.67 * w.t_c / (w.t_c + 243.5)) * r.outdoor_humidity * 2.1674 / (w.t_c + 273.15))) AS outdoor_abs_humidity,
    CONVERT(decimal(5, 1), r.dehumidifier_humidity) AS dehumidifier_humidity,
    CONVERT(decimal(5, 1), r.target_low + cfg.rh_offset) AS target_low,
    CONVERT(decimal(5, 1), r.target_high + cfg.rh_offset) AS target_high,
    CASE
        WHEN r.indoor_humidity IS NULL OR r.target_high IS NULL THEN NULL
        WHEN r.indoor_humidity <= r.target_high THEN 1
        ELSE 0
    END AS at_or_below_target,
    CONVERT(decimal(6, 2), d.seconds_on / 60.0) AS minutes_on,
    d.decision_mode,
    CONVERT(decimal(9, 5), d.seconds_on / 3600.0 * cfg.watts / 1000.0) AS est_kwh,
    CONVERT(decimal(9, 5), d.seconds_on / 3600.0 * cfg.watts / 1000.0 * cfg.usd_per_kwh) AS est_cost_usd
FROM readings AS r
FULL OUTER JOIN dw.fact_dehumidifier_5min AS d ON d.bucket_start_utc = r.bucket_start_utc
CROSS APPLY (
    SELECT
        COALESCE(r.bucket_start_utc, d.bucket_start_utc) AS bucket_start_utc,
        COALESCE(r.date_key, d.date_key) AS date_key,
        COALESCE(r.time_key, d.time_key) AS time_key
) AS k
CROSS APPLY (SELECT CONVERT(float, (r.outdoor_temp_f - 32) * 5 / 9.0) AS t_c) AS w
JOIN dw.dim_date AS dd ON dd.date_key = k.date_key
CROSS JOIN cfg
WHERE cfg.report_start IS NULL
   OR CONVERT(datetime2(0), (k.bucket_start_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) >= cfg.report_start;
GO

/* Finished runs only: a run without an end (still going, or cut off by missing data) would
   distort the averages. */
CREATE VIEW rpt.fact_dehumidifier_session
AS
SELECT
    CONVERT(datetime2(0), (s.session_start_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) AS start_local,
    CONVERT(datetime2(0), (s.session_end_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) AS end_local,
    dd.calendar_date,
    s.minutes_on,
    s.device_mode,
    s.decision_mode,
    CONVERT(decimal(5, 1), s.humidity_start + cfg.rh_offset) AS humidity_start,
    CONVERT(decimal(5, 1), s.humidity_end + cfg.rh_offset) AS humidity_end,
    CONVERT(decimal(5, 1), s.humidity_start - s.humidity_end) AS humidity_drop,
    s.is_complete
FROM dw.fact_dehumidifier_session AS s
JOIN dw.dim_date AS dd ON dd.date_key = s.start_date_key
CROSS JOIN (
    SELECT
        COALESCE(MAX(CASE WHEN setting_key = 'time_zone' THEN setting_value END), N'UTC') AS time_zone,
        COALESCE(MAX(CASE WHEN setting_key = 'indoor_humidity_offset' THEN TRY_CONVERT(decimal(5, 2), setting_value) END), 0) AS rh_offset,
        TRY_CONVERT(datetime2(0), MAX(CASE WHEN setting_key = 'report_start_local' THEN NULLIF(setting_value, N'') END), 126) AS report_start
    FROM dw.setting
) AS cfg
WHERE s.session_end_utc IS NOT NULL
  AND (cfg.report_start IS NULL
       OR CONVERT(datetime2(0), (s.session_start_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) >= cfg.report_start);
GO

CREATE VIEW rpt.fact_event
AS
SELECT
    CONVERT(datetime2(0), (e.event_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) AS event_local,
    dd.calendar_date,
    CASE e.event_type
        -- the Cube drains through its pump hose: its "bucket full" sensor marks the pump emptying it
        WHEN 'bucket_full' THEN 'Bucket Emptied (Pump)'
        WHEN 'too_hot' THEN 'Too Hot'
        WHEN 'mode_change' THEN 'Mode Change'
        WHEN 'auto_on' THEN 'Automation On'
        WHEN 'auto_off' THEN 'Automation Off'
        ELSE e.event_type
    END AS event_name,
    e.detail
FROM dw.fact_event AS e
JOIN dw.dim_date AS dd ON dd.date_key = e.date_key
CROSS JOIN (
    SELECT
        COALESCE(MAX(CASE WHEN setting_key = 'time_zone' THEN setting_value END), N'UTC') AS time_zone,
        TRY_CONVERT(datetime2(0), MAX(CASE WHEN setting_key = 'report_start_local' THEN NULLIF(setting_value, N'') END), 126) AS report_start
    FROM dw.setting
) AS cfg
WHERE cfg.report_start IS NULL
   OR CONVERT(datetime2(0), (e.event_utc AT TIME ZONE 'UTC') AT TIME ZONE cfg.time_zone) >= cfg.report_start;
GO

/* One row per day, with a 7-day rolling average (window function). */
CREATE VIEW rpt.daily_climate
AS
WITH daily AS
(
    SELECT
        c.calendar_date,
        AVG(c.indoor_humidity) AS avg_indoor_humidity,
        MIN(c.indoor_humidity) AS min_indoor_humidity,
        MAX(c.indoor_humidity) AS max_indoor_humidity,
        AVG(c.indoor_temp_f) AS avg_indoor_temp_f,
        AVG(c.outdoor_temp_f) AS avg_outdoor_temp_f,
        AVG(c.outdoor_abs_humidity) AS avg_outdoor_abs_humidity,
        AVG(c.target_high) AS avg_target_high,
        AVG(CONVERT(decimal(6, 4), c.at_or_below_target)) AS share_at_or_below_target,
        SUM(c.minutes_on) / 60.0 AS runtime_hours,
        SUM(c.est_kwh) AS est_kwh,
        SUM(c.est_cost_usd) AS est_cost_usd
    FROM rpt.fact_climate_5min AS c
    GROUP BY c.calendar_date
)
SELECT
    d.calendar_date,
    CONVERT(decimal(5, 1), d.avg_indoor_humidity) AS avg_indoor_humidity,
    CONVERT(decimal(5, 1), d.min_indoor_humidity) AS min_indoor_humidity,
    CONVERT(decimal(5, 1), d.max_indoor_humidity) AS max_indoor_humidity,
    CONVERT(decimal(5, 1), AVG(d.avg_indoor_humidity) OVER (ORDER BY d.calendar_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW))
        AS rolling_7_day_indoor_humidity,
    CONVERT(decimal(5, 1), d.avg_indoor_temp_f) AS avg_indoor_temp_f,
    CONVERT(decimal(5, 1), d.avg_outdoor_temp_f) AS avg_outdoor_temp_f,
    CONVERT(decimal(5, 1), d.avg_outdoor_abs_humidity) AS avg_outdoor_abs_humidity,
    CONVERT(decimal(5, 1), d.avg_target_high) AS avg_target_high,
    CONVERT(decimal(5, 1), 100 * d.share_at_or_below_target) AS pct_time_at_or_below_target,
    CONVERT(decimal(6, 2), d.runtime_hours) AS runtime_hours,
    CONVERT(decimal(8, 3), d.est_kwh) AS est_kwh,
    CONVERT(decimal(8, 3), d.est_cost_usd) AS est_cost_usd,
    -- from the report views, so both start where the reports start
    (SELECT COUNT(*)
     FROM rpt.fact_dehumidifier_session AS s
     WHERE s.calendar_date = d.calendar_date) AS dehumidifier_runs,
    (SELECT COUNT(*)
     FROM rpt.fact_event AS e
     WHERE e.calendar_date = d.calendar_date AND e.event_name = 'Bucket Emptied (Pump)') AS bucket_full_events
FROM daily AS d;
GO

/* The report's calendar: from the first day with readings through today, so the date range box
   always matches the data (rpt.dim_date has whole years, for the sales report's year-over-year). */
CREATE VIEW rpt.dim_date_observed
AS
SELECT
    d.date_key, d.calendar_date, d.calendar_year, d.quarter_label, d.month_number, d.month_name,
    d.month_short, d.year_month, d.month_start, d.day_of_month, d.day_of_week, d.day_name, d.day_short,
    d.is_weekend, d.iso_week, d.week_start, d.season
FROM rpt.dim_date AS d
CROSS JOIN (
    SELECT
        (SELECT MIN(bucket_start_utc) FROM dw.fact_reading_5min) AS first_utc,
        (SELECT COALESCE(MAX(setting_value), N'UTC') FROM dw.setting WHERE setting_key = 'time_zone') AS time_zone
) AS b
WHERE d.calendar_date >= CONVERT(date, (b.first_utc AT TIME ZONE 'UTC') AT TIME ZONE b.time_zone)
  AND d.calendar_date <= CONVERT(date, (SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE b.time_zone);
GO
