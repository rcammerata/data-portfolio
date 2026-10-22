/* Loader entry points. The loader (homebase/lib/portfolio_climate.py) sends JSON; these
   procedures shred it with OPENJSON. They run as the owner, so the etl login needs nothing but
   EXECUTE on this schema. */

/* Latest state time already stored: the loader asks Home Assistant for everything after it. */
CREATE PROCEDURE etl.usp_get_watermark
    @result nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET @result = (
        SELECT CONVERT(varchar(23), MAX(last_updated), 126) AS last_updated_utc
        FROM raw.ha_state
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
    );
END;
GO

/* Stores a batch of state changes. Payload: [{"e": entity_id, "s": state, "a": {attributes},
   "c": last_changed, "u": last_updated}, ...] with UTC times like 2026-10-16T14:03:11.123.
   Rows already stored (same entity and time) are skipped, so overlapping windows are harmless. */
CREATE PROCEDURE etl.usp_ingest_ha_states
    @payload      nvarchar(max),
    @window_start datetime2(3) = NULL,
    @window_end   datetime2(3) = NULL,
    @result       nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@payload) <> 1
        THROW 50001, N'The payload is not valid JSON.', 1;

    DECLARE @batch_id int, @received int, @inserted int;

    CREATE TABLE #incoming
    (
        entity_id    varchar(255)  NOT NULL,
        state        nvarchar(255) NULL,
        attributes   nvarchar(max) NULL,
        last_changed datetime2(3)  NULL,
        last_updated datetime2(3)  NOT NULL
    );

    INSERT INTO #incoming (entity_id, state, attributes, last_changed, last_updated)
    SELECT
        j.entity_id,
        LEFT(j.state, 255),
        CASE WHEN j.attributes IS NULL OR j.attributes = N'{}' THEN NULL ELSE j.attributes END,
        j.last_changed,
        j.last_updated
    FROM OPENJSON(@payload)
         WITH (
             entity_id    varchar(255)  '$.e',
             state        nvarchar(max) '$.s',
             attributes   nvarchar(max) '$.a' AS JSON,
             last_changed datetime2(3)  '$.c',
             last_updated datetime2(3)  '$.u'
         ) AS j
    WHERE j.entity_id IS NOT NULL
      AND j.last_updated IS NOT NULL;

    SET @received = @@ROWCOUNT;

    BEGIN TRANSACTION;

    INSERT INTO raw.load_batch (source_name, window_start, window_end, rows_received)
    VALUES ('home_assistant', @window_start, @window_end, @received);
    SET @batch_id = CONVERT(int, SCOPE_IDENTITY());

    WITH ranked AS
    (
        SELECT
            i.entity_id, i.state, i.attributes, i.last_changed, i.last_updated,
            ROW_NUMBER() OVER (PARTITION BY i.entity_id, i.last_updated ORDER BY i.last_changed DESC) AS rn
        FROM #incoming AS i
    )
    INSERT INTO raw.ha_state (entity_id, state, attributes, last_changed, last_updated, batch_id)
    SELECT r.entity_id, r.state, r.attributes, COALESCE(r.last_changed, r.last_updated), r.last_updated, @batch_id
    FROM ranked AS r
    WHERE r.rn = 1
      AND NOT EXISTS (
          SELECT 1
          FROM raw.ha_state AS h
          WHERE h.entity_id = r.entity_id
            AND h.last_updated = r.last_updated
      );

    SET @inserted = @@ROWCOUNT;

    UPDATE raw.load_batch SET rows_inserted = @inserted WHERE batch_id = @batch_id;

    COMMIT TRANSACTION;

    SET @result = (
        SELECT @batch_id AS batch_id, @received AS rows_received, @inserted AS rows_inserted
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
END;
GO

/* Tells the warehouse which entities to read. Payload:
   {"metrics": [{"entity_id", "metric_code", "value_source", "attribute_path", "unit_path"}],
    "roles":   [{"role_code", "entity_id"}]}
   New rows are added and changed paths updated; nothing is removed (history stays mapped). */
CREATE PROCEDURE etl.usp_set_entities
    @payload nvarchar(max),
    @result  nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@payload) <> 1
        THROW 50001, N'The payload is not valid JSON.', 1;

    CREATE TABLE #metric
    (
        entity_id      varchar(255) NOT NULL,
        metric_key     tinyint      NOT NULL,
        value_source   varchar(20)  NOT NULL,
        attribute_path varchar(100) NULL,
        unit_path      varchar(100) NULL
    );

    INSERT INTO #metric (entity_id, metric_key, value_source, attribute_path, unit_path)
    SELECT DISTINCT j.entity_id, m.metric_key, j.value_source, j.attribute_path, j.unit_path
    FROM OPENJSON(@payload, '$.metrics')
         WITH (
             entity_id      varchar(255) '$.entity_id',
             metric_code    varchar(40)  '$.metric_code',
             value_source   varchar(20)  '$.value_source',
             attribute_path varchar(100) '$.attribute_path',
             unit_path      varchar(100) '$.unit_path'
         ) AS j
    JOIN dw.dim_metric AS m ON m.metric_code = j.metric_code
    WHERE j.entity_id LIKE '%_._%'
      AND j.value_source IN ('state', 'attribute', 'band_low', 'band_high');

    BEGIN TRANSACTION;

    UPDATE em
    SET em.value_source = m.value_source,
        em.attribute_path = m.attribute_path,
        em.unit_path = m.unit_path
    FROM dw.entity_map AS em
    JOIN #metric AS m ON m.entity_id = em.entity_id AND m.metric_key = em.metric_key;

    INSERT INTO dw.entity_map (entity_id, metric_key, value_source, attribute_path, unit_path)
    SELECT m.entity_id, m.metric_key, m.value_source, m.attribute_path, m.unit_path
    FROM #metric AS m
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.entity_map AS em
        WHERE em.entity_id = m.entity_id AND em.metric_key = m.metric_key
    );

    INSERT INTO dw.entity_role (role_code, entity_id)
    SELECT DISTINCT j.role_code, j.entity_id
    FROM OPENJSON(@payload, '$.roles')
         WITH (
             role_code varchar(40)  '$.role_code',
             entity_id varchar(255) '$.entity_id'
         ) AS j
    WHERE j.role_code IN ('dehumidifier', 'decision_mode', 'auto_switch', 'tank_full', 'too_hot')
      AND j.entity_id LIKE '%_._%'
      AND NOT EXISTS (
          SELECT 1 FROM dw.entity_role AS r
          WHERE r.role_code = j.role_code AND r.entity_id = j.entity_id
      );

    COMMIT TRANSACTION;

    SET @result = (
        SELECT (SELECT COUNT(*) FROM dw.entity_map) AS metric_links,
               (SELECT COUNT(*) FROM dw.entity_role) AS role_links
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
END;
GO
