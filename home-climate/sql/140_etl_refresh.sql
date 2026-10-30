/*
  Rebuilds the facts for one time window from the raw state changes. Safe to re-run for any
  window: everything in it is deleted and computed again.

  - 5-minute buckets: time-weighted averages, each reading counted for as long as it was current
  - dehumidifier runs: gaps and islands over the on/off changes
  - events: LAG over each entity's states
*/
CREATE PROCEDURE etl.usp_refresh_climate
    @from_utc datetime2(0),
    @to_utc   datetime2(0),
    @result   nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @from_utc IS NULL OR @to_utc IS NULL
        THROW 50002, N'Both @from_utc and @to_utc are required.', 1;

    DECLARE @epoch datetime2(0) = '2000-01-01T00:00:00';
    DECLARE @tz sysname = COALESCE((SELECT MAX(setting_value) FROM dw.setting WHERE setting_key = 'time_zone'), N'UTC');
    DECLARE @stale int = COALESCE((SELECT MAX(TRY_CONVERT(int, setting_value)) FROM dw.setting WHERE setting_key = 'stale_minutes'), 720);
    DECLARE @readings int = 0, @dehumidifier int = 0, @sessions int = 0, @events int = 0;

    -- Whole 5-minute buckets only.
    SET @from_utc = DATEADD(minute, (DATEDIFF(minute, @epoch, @from_utc) / 5) * 5, @epoch);
    SET @to_utc = DATEADD(minute, ((DATEDIFF(minute, @epoch, @to_utc) + 4) / 5) * 5, @epoch);

    IF @to_utc > @from_utc
    BEGIN
        DECLARE @first_day date = DATEADD(day, -1, CONVERT(date, @from_utc));
        DECLARE @last_day date = DATEADD(day, 1, CONVERT(date, @to_utc));
        EXEC etl.usp_ensure_dates @from = @first_day, @to = @last_day;

        ------------------------------------------------------------------ the buckets
        CREATE TABLE #bucket
        (
            bucket_start datetime2(0) NOT NULL PRIMARY KEY,
            bucket_end   datetime2(0) NOT NULL,
            date_key     int          NOT NULL,
            time_key     smallint     NOT NULL
        );

        INSERT INTO #bucket (bucket_start, bucket_end, date_key, time_key)
        SELECT
            b.bucket_start,
            DATEADD(minute, 5, b.bucket_start),
            YEAR(l.local_ts) * 10000 + MONTH(l.local_ts) * 100 + DAY(l.local_ts),
            CONVERT(smallint, DATEPART(hour, l.local_ts) * 60 + DATEPART(minute, l.local_ts))
        FROM GENERATE_SERIES(0, DATEDIFF(minute, @from_utc, @to_utc) / 5 - 1) AS g
        CROSS APPLY (SELECT DATEADD(minute, 5 * g.value, @from_utc) AS bucket_start) AS b
        CROSS APPLY (SELECT CONVERT(datetime2(0), (b.bucket_start AT TIME ZONE 'UTC') AT TIME ZONE @tz) AS local_ts) AS l;

        ------------------------------------------------------------------ readings
        -- Each numeric value holds from its time until the next state of the same entity
        -- (at most @stale minutes). "unavailable" states end a value without starting one.
        -- The target band is a setting, not a sensor: it can go days unchanged, so it holds until
        -- the next state with no @stale limit.
        CREATE TABLE #interval
        (
            metric_key tinyint        NOT NULL,
            t0         datetime2(3)   NOT NULL,
            t1         datetime2(3)   NOT NULL,
            v          decimal(12, 3) NOT NULL
        );

        WITH src AS
        (
            SELECT
                m.metric_key,
                m.value_source,
                s.last_updated AS t0,
                LEAD(s.last_updated) OVER (PARTITION BY m.metric_key, s.entity_id ORDER BY s.last_updated) AS t_next,
                CASE m.value_source
                    WHEN 'state' THEN TRY_CONVERT(decimal(12, 3), s.state)
                    WHEN 'attribute' THEN TRY_CONVERT(decimal(12, 3), JSON_VALUE(s.attributes, m.attribute_path))
                    WHEN 'band_low' THEN TRY_CONVERT(decimal(12, 3), LEFT(s.state, NULLIF(CHARINDEX('-', s.state), 0) - 1))
                    WHEN 'band_high' THEN TRY_CONVERT(decimal(12, 3),
                        REPLACE(SUBSTRING(s.state, NULLIF(CHARINDEX('-', s.state), 0) + 1, 20), '%', ''))
                END AS raw_value,
                CASE WHEN m.unit_path IS NOT NULL THEN JSON_VALUE(s.attributes, m.unit_path) END AS unit
            FROM dw.entity_map AS m
            CROSS APPLY dw.tvf_entity_states(m.entity_id, @from_utc, @to_utc) AS s
        )
        INSERT INTO #interval (metric_key, t0, t1, v)
        SELECT
            src.metric_key,
            src.t0,
            CASE WHEN src.value_source IN ('band_low', 'band_high') THEN COALESCE(src.t_next, @to_utc)
                 ELSE LEAST(COALESCE(src.t_next, @to_utc), DATEADD(minute, @stale, src.t0)) END,
            CASE WHEN src.unit IN (N'°C', N'C') THEN src.raw_value * 9 / 5 + 32 ELSE src.raw_value END
        FROM src
        WHERE src.raw_value IS NOT NULL;

        CREATE TABLE #reading
        (
            bucket_start    datetime2(0)  NOT NULL,
            metric_key      tinyint       NOT NULL,
            date_key        int           NOT NULL,
            time_key        smallint      NOT NULL,
            avg_value       decimal(9, 3) NOT NULL,
            min_value       decimal(9, 3) NOT NULL,
            max_value       decimal(9, 3) NOT NULL,
            covered_seconds smallint      NOT NULL
        );

        INSERT INTO #reading (bucket_start, metric_key, date_key, time_key, avg_value, min_value, max_value, covered_seconds)
        SELECT
            b.bucket_start,
            i.metric_key,
            b.date_key,
            b.time_key,
            CONVERT(decimal(9, 3), SUM(i.v * o.secs) / SUM(o.secs)),
            CONVERT(decimal(9, 3), MIN(i.v)),
            CONVERT(decimal(9, 3), MAX(i.v)),
            CONVERT(smallint, LEAST(SUM(o.secs), 300))
        FROM #interval AS i
        JOIN #bucket AS b ON i.t0 < b.bucket_end AND i.t1 > b.bucket_start
        CROSS APPLY (SELECT DATEDIFF(second, GREATEST(i.t0, b.bucket_start), LEAST(i.t1, b.bucket_end)) AS secs) AS o
        WHERE o.secs > 0
        GROUP BY b.bucket_start, i.metric_key, b.date_key, b.time_key;

        ------------------------------------------------------------------ dehumidifier on/off
        CREATE TABLE #dehumidifier
        (
            bucket_start  datetime2(0) NOT NULL PRIMARY KEY,
            seconds_on    int          NOT NULL,
            seconds_known int          NOT NULL
        );

        WITH dev AS
        (
            SELECT
                s.last_updated AS t0,
                LEAD(s.last_updated) OVER (PARTITION BY s.entity_id ORDER BY s.last_updated) AS t_next,
                s.state
            FROM dw.entity_role AS r
            CROSS APPLY dw.tvf_entity_states(r.entity_id, @from_utc, @to_utc) AS s
            WHERE r.role_code = 'dehumidifier'
        ),
        dev_interval AS
        (
            SELECT
                dev.t0,
                LEAST(COALESCE(dev.t_next, @to_utc), DATEADD(minute, @stale, dev.t0)) AS t1,
                CASE WHEN dev.state = N'on' THEN 1 ELSE 0 END AS is_on
            FROM dev
            WHERE dev.state IN (N'on', N'off')
        )
        INSERT INTO #dehumidifier (bucket_start, seconds_on, seconds_known)
        SELECT b.bucket_start, SUM(d.is_on * o.secs), SUM(o.secs)
        FROM dev_interval AS d
        JOIN #bucket AS b ON d.t0 < b.bucket_end AND d.t1 > b.bucket_start
        CROSS APPLY (SELECT DATEDIFF(second, GREATEST(d.t0, b.bucket_start), LEAST(d.t1, b.bucket_end)) AS secs) AS o
        WHERE o.secs > 0
        GROUP BY b.bucket_start;

        ------------------------------------------------------------------ the automation's decision
        -- The mode (Max / Min / Off) that held for the longest part of each bucket.
        CREATE TABLE #decision
        (
            bucket_start  datetime2(0) NOT NULL PRIMARY KEY,
            decision_mode nvarchar(10) NOT NULL
        );

        WITH dm AS
        (
            SELECT
                s.last_updated AS t0,
                COALESCE(LEAD(s.last_updated) OVER (PARTITION BY s.entity_id ORDER BY s.last_updated), @to_utc) AS t1,
                s.state
            FROM dw.entity_role AS r
            CROSS APPLY dw.tvf_entity_states(r.entity_id, @from_utc, @to_utc) AS s
            WHERE r.role_code = 'decision_mode'
        ),
        ranked AS
        (
            SELECT
                b.bucket_start,
                dm.state,
                ROW_NUMBER() OVER (PARTITION BY b.bucket_start ORDER BY o.secs DESC, dm.t0 DESC) AS rn
            FROM dm
            JOIN #bucket AS b ON dm.t0 < b.bucket_end AND dm.t1 > b.bucket_start
            CROSS APPLY (SELECT DATEDIFF(second, GREATEST(dm.t0, b.bucket_start), LEAST(dm.t1, b.bucket_end)) AS secs) AS o
            WHERE dm.state IN (N'Max', N'Min', N'Off')
        )
        INSERT INTO #decision (bucket_start, decision_mode)
        SELECT ranked.bucket_start, ranked.state
        FROM ranked
        WHERE ranked.rn = 1;

        ------------------------------------------------------------------ events
        CREATE TABLE #event
        (
            event_utc  datetime2(3)  NOT NULL,
            event_type varchar(30)   NOT NULL,
            detail     nvarchar(100) NULL
        );

        WITH ev AS
        (
            SELECT
                r.role_code,
                s.last_updated AS t,
                s.state,
                LAG(s.state) OVER (PARTITION BY r.role_code, s.entity_id ORDER BY s.last_updated) AS prev_state
            FROM dw.entity_role AS r
            CROSS APPLY dw.tvf_entity_states(r.entity_id, @from_utc, @to_utc) AS s
            WHERE r.role_code IN ('tank_full', 'too_hot', 'decision_mode', 'auto_switch')
        ),
        typed AS
        (
            SELECT
                ev.t,
                CASE
                    WHEN ev.role_code = 'tank_full' AND ev.state = N'on' AND (ev.prev_state = N'off' OR ev.prev_state IS NULL) THEN 'bucket_full'
                    WHEN ev.role_code = 'too_hot' AND ev.state = N'on' AND (ev.prev_state = N'off' OR ev.prev_state IS NULL) THEN 'too_hot'
                    WHEN ev.role_code = 'decision_mode' AND ev.state IN (N'Max', N'Min', N'Off')
                         AND ev.prev_state IN (N'Max', N'Min', N'Off') AND ev.state <> ev.prev_state THEN 'mode_change'
                    WHEN ev.role_code = 'auto_switch' AND ev.state = N'on' AND ev.prev_state = N'off' THEN 'auto_on'
                    WHEN ev.role_code = 'auto_switch' AND ev.state = N'off' AND ev.prev_state = N'on' THEN 'auto_off'
                END AS event_type,
                CASE WHEN ev.role_code = 'decision_mode' THEN CONCAT(ev.prev_state, N' to ', ev.state) END AS detail
            FROM ev
            WHERE ev.t >= @from_utc
        )
        INSERT INTO #event (event_utc, event_type, detail)
        SELECT typed.t, typed.event_type, MAX(typed.detail)
        FROM typed
        WHERE typed.event_type IS NOT NULL
        GROUP BY typed.t, typed.event_type;

        ------------------------------------------------------------------ write the window
        BEGIN TRANSACTION;

        DELETE FROM dw.fact_reading_5min
        WHERE bucket_start_utc >= @from_utc AND bucket_start_utc < @to_utc;

        INSERT INTO dw.fact_reading_5min
            (bucket_start_utc, metric_key, date_key, time_key, avg_value, min_value, max_value, covered_seconds)
        SELECT bucket_start, metric_key, date_key, time_key, avg_value, min_value, max_value, covered_seconds
        FROM #reading;
        SET @readings = @@ROWCOUNT;

        DELETE FROM dw.fact_dehumidifier_5min
        WHERE bucket_start_utc >= @from_utc AND bucket_start_utc < @to_utc;

        INSERT INTO dw.fact_dehumidifier_5min (bucket_start_utc, date_key, time_key, seconds_on, seconds_known, decision_mode)
        SELECT
            b.bucket_start,
            b.date_key,
            b.time_key,
            CONVERT(smallint, LEAST(d.seconds_on, 300)),
            CONVERT(smallint, LEAST(d.seconds_known, 300)),
            x.decision_mode
        FROM #bucket AS b
        LEFT JOIN #dehumidifier AS d ON d.bucket_start = b.bucket_start
        LEFT JOIN #decision AS x ON x.bucket_start = b.bucket_start
        WHERE d.bucket_start IS NOT NULL OR x.bucket_start IS NOT NULL;
        SET @dehumidifier = @@ROWCOUNT;

        DELETE FROM dw.fact_event
        WHERE event_utc >= @from_utc AND event_utc < @to_utc;

        INSERT INTO dw.fact_event (event_utc, event_type, date_key, detail)
        SELECT
            e.event_utc,
            e.event_type,
            YEAR(l.local_ts) * 10000 + MONTH(l.local_ts) * 100 + DAY(l.local_ts),
            e.detail
        FROM #event AS e
        CROSS APPLY (SELECT CONVERT(datetime2(0), (e.event_utc AT TIME ZONE 'UTC') AT TIME ZONE @tz) AS local_ts) AS l;
        SET @events = @@ROWCOUNT;

        COMMIT TRANSACTION;

        ------------------------------------------------------------------ dehumidifier runs
        -- Recomputed from the start of the earliest run that was still open at @from_utc.
        DECLARE @anchor datetime2(0) = (
            SELECT MIN(session_start_utc)
            FROM dw.fact_dehumidifier_session
            WHERE session_end_utc IS NULL OR session_end_utc >= @from_utc
        );
        IF @anchor IS NULL OR @anchor > @from_utc
            SET @anchor = @from_utc;

        CREATE TABLE #run
        (
            entity_id   varchar(255) NOT NULL,
            start_t     datetime2(3) NOT NULL,
            end_t       datetime2(3) NULL,
            device_mode nvarchar(40) NULL
        );

        WITH st AS
        (
            SELECT
                s.entity_id,
                s.last_updated AS t,
                CASE WHEN s.state = N'on' THEN 1 ELSE 0 END AS is_on,
                JSON_VALUE(s.attributes, '$.mode') AS device_mode
            FROM dw.entity_role AS r
            CROSS APPLY dw.tvf_entity_states(r.entity_id, @anchor, @to_utc) AS s
            WHERE r.role_code = 'dehumidifier'
              AND s.state IN (N'on', N'off')
        ),
        numbered AS
        (
            -- Gaps and islands: inside a stretch of identical on/off values both row numbers grow
            -- together, so their difference stays constant and labels the stretch.
            SELECT
                st.entity_id,
                st.t,
                st.is_on,
                ROW_NUMBER() OVER (PARTITION BY st.entity_id ORDER BY st.t)
                    - ROW_NUMBER() OVER (PARTITION BY st.entity_id, st.is_on ORDER BY st.t) AS island
            FROM st
        ),
        islands AS
        (
            SELECT numbered.entity_id, numbered.is_on, numbered.island, MIN(numbered.t) AS start_t
            FROM numbered
            GROUP BY numbered.entity_id, numbered.is_on, numbered.island
        ),
        runs AS
        (
            SELECT
                islands.entity_id,
                islands.is_on,
                islands.start_t,
                LEAD(islands.start_t) OVER (PARTITION BY islands.entity_id ORDER BY islands.start_t) AS end_t
            FROM islands
        )
        INSERT INTO #run (entity_id, start_t, end_t, device_mode)
        SELECT runs.entity_id, runs.start_t, runs.end_t, first_state.device_mode
        FROM runs
        OUTER APPLY (
            SELECT TOP (1) st.device_mode
            FROM st
            WHERE st.entity_id = runs.entity_id AND st.t = runs.start_t
        ) AS first_state
        WHERE runs.is_on = 1;

        BEGIN TRANSACTION;

        DELETE FROM dw.fact_dehumidifier_session
        WHERE session_start_utc >= @anchor;

        DELETE s
        FROM dw.fact_dehumidifier_session AS s
        JOIN #run AS r ON r.entity_id = s.entity_id AND CONVERT(datetime2(0), r.start_t) = s.session_start_utc;

        INSERT INTO dw.fact_dehumidifier_session
            (session_start_utc, entity_id, session_end_utc, start_date_key, minutes_on, device_mode, decision_mode,
             humidity_start, humidity_end, is_complete)
        SELECT
            CONVERT(datetime2(0), r.start_t),
            r.entity_id,
            CONVERT(datetime2(0), r.end_t),
            YEAR(l.local_ts) * 10000 + MONTH(l.local_ts) * 100 + DAY(l.local_ts),
            CONVERT(decimal(9, 2), DATEDIFF(second, r.start_t, COALESCE(r.end_t, @to_utc)) / 60.0),
            r.device_mode,
            dec.decision_mode,
            CONVERT(decimal(5, 1), h0.avg_value),
            CONVERT(decimal(5, 1), h1.avg_value),
            CASE WHEN r.end_t IS NULL THEN 0 ELSE 1 END
        FROM #run AS r
        CROSS APPLY (SELECT CONVERT(datetime2(0), (r.start_t AT TIME ZONE 'UTC') AT TIME ZONE @tz) AS local_ts) AS l
        OUTER APPLY (
            SELECT TOP (1) f.avg_value
            FROM dw.fact_reading_5min AS f
            JOIN dw.dim_metric AS m ON m.metric_key = f.metric_key
            WHERE m.metric_code = 'indoor_humidity'
              AND f.bucket_start_utc <= r.start_t
              AND f.bucket_start_utc >= DATEADD(hour, -2, r.start_t)
            ORDER BY f.bucket_start_utc DESC
        ) AS h0
        OUTER APPLY (
            SELECT TOP (1) f.avg_value
            FROM dw.fact_reading_5min AS f
            JOIN dw.dim_metric AS m ON m.metric_key = f.metric_key
            WHERE m.metric_code = 'indoor_humidity'
              AND f.bucket_start_utc <= COALESCE(r.end_t, @to_utc)
              AND f.bucket_start_utc >= DATEADD(hour, -2, COALESCE(r.end_t, @to_utc))
            ORDER BY f.bucket_start_utc DESC
        ) AS h1
        OUTER APPLY (
            SELECT TOP (1) x.decision_mode
            FROM dw.fact_dehumidifier_5min AS x
            WHERE x.bucket_start_utc <= r.start_t
              AND x.bucket_start_utc >= DATEADD(hour, -2, r.start_t)
              AND x.decision_mode IS NOT NULL
            ORDER BY x.bucket_start_utc DESC
        ) AS dec;
        SET @sessions = @@ROWCOUNT;

        COMMIT TRANSACTION;
    END;

    SET @result = (
        SELECT
            CONVERT(varchar(19), @from_utc, 126) AS from_utc,
            CONVERT(varchar(19), @to_utc, 126) AS to_utc,
            @readings AS reading_rows,
            @dehumidifier AS dehumidifier_rows,
            @sessions AS session_rows,
            @events AS event_rows
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
END;
GO
