/*
  Home climate: landing tables. Rows arrive exactly as Home Assistant recorded them
  (one row per state change), so every later step can be rebuilt from here.
*/
CREATE SCHEMA raw AUTHORIZATION dbo;
GO

CREATE TABLE raw.load_batch
(
    batch_id      int           IDENTITY(1, 1) NOT NULL,
    source_name   varchar(40)   NOT NULL,
    started_utc   datetime2(0)  NOT NULL CONSTRAINT DF_load_batch_started DEFAULT (SYSUTCDATETIME()),
    window_start  datetime2(3)  NULL,
    window_end    datetime2(3)  NULL,
    rows_received int           NOT NULL CONSTRAINT DF_load_batch_received DEFAULT (0),
    rows_inserted int           NOT NULL CONSTRAINT DF_load_batch_inserted DEFAULT (0),
    CONSTRAINT PK_load_batch PRIMARY KEY CLUSTERED (batch_id)
);
GO

/* One row per Home Assistant state change. Times are UTC. attributes holds the state's JSON
   attributes (unit, the dehumidifier's mode, the weather's temperature, ...). */
CREATE TABLE raw.ha_state
(
    state_id     bigint         IDENTITY(1, 1) NOT NULL,
    entity_id    varchar(255)   NOT NULL,
    state        nvarchar(255)  NULL,
    attributes   nvarchar(max)  NULL,
    last_changed datetime2(3)   NOT NULL,
    last_updated datetime2(3)   NOT NULL,
    batch_id     int            NULL,
    CONSTRAINT PK_ha_state PRIMARY KEY NONCLUSTERED (state_id),
    CONSTRAINT CK_ha_state_attributes_json CHECK (attributes IS NULL OR ISJSON(attributes) = 1)
);
GO

-- Time-ordered storage: loads append at the end, and the transforms read time windows.
CREATE UNIQUE CLUSTERED INDEX CX_ha_state_time ON raw.ha_state (last_updated, entity_id);
GO

-- "Latest state of this entity before time X" lookups.
CREATE NONCLUSTERED INDEX IX_ha_state_entity ON raw.ha_state (entity_id, last_updated) INCLUDE (state);
GO
