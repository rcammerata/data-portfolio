/* Defaults and fixed lists; the deploy tool runs this after every deployment (safe to repeat). */
CREATE PROCEDURE etl.usp_post_deploy
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    EXEC etl.usp_default_setting 'time_zone', N'UTC',
        N'Windows time zone name for local dates and times (set from the PC during setup).';
    EXEC etl.usp_default_setting 'stale_minutes', N'720',
        N'A reading counts for at most this many minutes if no newer value arrives.';
    EXEC etl.usp_default_setting 'dehumidifier_watts', N'380',
        N'Assumed power draw while running. A Midea Cube measured about 374 W at full power.';
    EXEC etl.usp_default_setting 'electricity_usd_per_kwh', N'0.182',
        N'Assumed electricity price: the 2026 U.S. residential average forecast by the EIA.';
    EXEC etl.usp_default_setting 'public_delay_days', N'3',
        N'The public summaries leave out the most recent days.';

    DECLARE @calendar_from nvarchar(200) = CONVERT(nvarchar(10), DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1), 23);
    EXEC etl.usp_default_setting 'calendar_from', @calendar_from, N'First day of the Power BI calendar.';

    INSERT INTO dw.dim_metric (metric_key, metric_code, metric_name, unit)
    SELECT v.metric_key, v.metric_code, v.metric_name, v.unit
    FROM (VALUES
        (CONVERT(tinyint, 1), 'indoor_humidity',       N'Indoor humidity',             N'%'),
        (CONVERT(tinyint, 2), 'indoor_temp_f',         N'Indoor temperature',          N'°F'),
        (CONVERT(tinyint, 3), 'outdoor_temp_f',        N'Outdoor temperature',         N'°F'),
        (CONVERT(tinyint, 4), 'outdoor_humidity',      N'Outdoor humidity',            N'%'),
        (CONVERT(tinyint, 5), 'outdoor_abs_humidity',  N'Outdoor absolute humidity',   N'g/m³'),
        (CONVERT(tinyint, 6), 'dehumidifier_humidity', N'Dehumidifier''s own reading', N'%'),
        (CONVERT(tinyint, 7), 'target_low',            N'Target band, low end',        N'%'),
        (CONVERT(tinyint, 8), 'target_high',           N'Target band, high end',       N'%')
    ) AS v (metric_key, metric_code, metric_name, unit)
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_metric AS m WHERE m.metric_key = v.metric_key);

    INSERT INTO dw.dim_time (time_key, hour_24, minute_of_hour, time_label, hour_label, part_of_day)
    SELECT
        t.k,
        CONVERT(tinyint, t.k / 60),
        CONVERT(tinyint, t.k % 60),
        CONCAT(RIGHT(CONCAT('0', t.k / 60), 2), ':', RIGHT(CONCAT('0', t.k % 60), 2)),
        CONCAT(CASE WHEN t.k / 60 % 12 = 0 THEN 12 ELSE t.k / 60 % 12 END, CASE WHEN t.k < 720 THEN ' AM' ELSE ' PM' END),
        CASE WHEN t.k < 360 THEN 'Night'
             WHEN t.k < 720 THEN 'Morning'
             WHEN t.k < 1020 THEN 'Afternoon'
             WHEN t.k < 1320 THEN 'Evening'
             ELSE 'Night' END
    FROM (SELECT CONVERT(smallint, g.value * 5) AS k FROM GENERATE_SERIES(0, 287) AS g) AS t
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_time AS d WHERE d.time_key = t.k);

    DECLARE @first_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) - 1, 1, 1);
    DECLARE @last_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) + 1, 12, 31);
    EXEC etl.usp_ensure_dates @from = @first_day, @to = @last_day;
END;
GO

/* Nightly housekeeping (scheduled as a SQL Server Agent job). */
CREATE PROCEDURE etl.usp_nightly_maintenance
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @last_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) + 1, 12, 31);
    DECLARE @first_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1);
    EXEC etl.usp_ensure_dates @from = @first_day, @to = @last_day;

    DELETE FROM raw.load_batch WHERE started_utc < DATEADD(day, -180, SYSUTCDATETIME());

    UPDATE STATISTICS raw.ha_state;
    UPDATE STATISTICS dw.fact_reading_5min;
    UPDATE STATISTICS dw.fact_dehumidifier_5min;
END;
GO
