/* Home climate: star schema. Facts are 5-minute buckets keyed by their UTC start; date_key and
   time_key hold the local date and time of day (so a daylight-saving "repeat hour" is kept). */

/* Time of day in 5-minute steps (288 rows). */
CREATE TABLE dw.dim_time
(
    time_key       smallint    NOT NULL,   -- minutes after midnight: 0, 5, ..., 1435
    hour_24        tinyint     NOT NULL,
    minute_of_hour tinyint     NOT NULL,
    time_label     char(5)     NOT NULL,   -- 14:35
    hour_label     varchar(5)  NOT NULL,   -- 2 PM
    part_of_day    varchar(9)  NOT NULL,   -- Night, Morning, Afternoon, Evening
    CONSTRAINT PK_dim_time PRIMARY KEY CLUSTERED (time_key)
);
GO

/* What is measured. */
CREATE TABLE dw.dim_metric
(
    metric_key   tinyint       NOT NULL,
    metric_code  varchar(40)   NOT NULL,
    metric_name  nvarchar(60)  NOT NULL,
    unit         nvarchar(10)  NOT NULL,
    CONSTRAINT PK_dim_metric PRIMARY KEY CLUSTERED (metric_key),
    CONSTRAINT UQ_dim_metric_code UNIQUE (metric_code)
);
GO

/* Which Home Assistant entity feeds which metric, and where its number is:
     state       the state itself ("41.5")
     attribute   a JSON attribute (attribute_path, e.g. $.temperature on the weather entity)
     band_low / band_high   the two numbers of a "37-40 %" target text
   unit_path points at the unit attribute when the value may arrive in Celsius. Rows are only
   ever added, so history from a replaced sensor stays mapped. */
CREATE TABLE dw.entity_map
(
    entity_id       varchar(255)  NOT NULL,
    metric_key      tinyint       NOT NULL,
    value_source    varchar(20)   NOT NULL,
    attribute_path  varchar(100)  NULL,
    unit_path       varchar(100)  NULL,
    first_seen_utc  datetime2(0)  NOT NULL CONSTRAINT DF_entity_map_first_seen DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_entity_map PRIMARY KEY CLUSTERED (entity_id, metric_key),
    CONSTRAINT FK_entity_map_metric FOREIGN KEY (metric_key) REFERENCES dw.dim_metric (metric_key),
    CONSTRAINT CK_entity_map_source CHECK (value_source IN ('state', 'attribute', 'band_low', 'band_high'))
);
GO

/* Entities with a job in the transforms:
     dehumidifier   the Midea dehumidifier (on/off, mode)
     decision_mode  the automation's last decision (Max / Min / Off)
     auto_switch    "Dehumidifier auto" (the automation's on/off switch)
     tank_full      the bucket-full sensor
     too_hot        the "Apartment hot" alert sensor */
CREATE TABLE dw.entity_role
(
    role_code       varchar(40)   NOT NULL,
    entity_id       varchar(255)  NOT NULL,
    first_seen_utc  datetime2(0)  NOT NULL CONSTRAINT DF_entity_role_first_seen DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_entity_role PRIMARY KEY CLUSTERED (role_code, entity_id)
);
GO

/* Time-weighted 5-minute readings: a value counts for as long as it was the current value. */
CREATE TABLE dw.fact_reading_5min
(
    bucket_start_utc datetime2(0)  NOT NULL,
    metric_key       tinyint       NOT NULL,
    date_key         int           NOT NULL,
    time_key         smallint      NOT NULL,
    avg_value        decimal(9, 3) NOT NULL,
    min_value        decimal(9, 3) NOT NULL,
    max_value        decimal(9, 3) NOT NULL,
    covered_seconds  smallint      NOT NULL,
    CONSTRAINT PK_fact_reading_5min PRIMARY KEY CLUSTERED (bucket_start_utc, metric_key),
    CONSTRAINT FK_fact_reading_5min_metric FOREIGN KEY (metric_key) REFERENCES dw.dim_metric (metric_key)
);
GO

CREATE NONCLUSTERED INDEX IX_fact_reading_5min_date ON dw.fact_reading_5min (date_key, metric_key) INCLUDE (avg_value);
GO

/* What the dehumidifier did in each 5-minute bucket. */
CREATE TABLE dw.fact_dehumidifier_5min
(
    bucket_start_utc datetime2(0)  NOT NULL,
    date_key         int           NOT NULL,
    time_key         smallint      NOT NULL,
    seconds_on       smallint      NULL,   -- NULL when the dehumidifier's state is unknown
    seconds_known    smallint      NULL,
    decision_mode    nvarchar(10)  NULL,   -- the automation's choice: Max, Min or Off
    CONSTRAINT PK_fact_dehumidifier_5min PRIMARY KEY CLUSTERED (bucket_start_utc)
);
GO

/* One row per continuous run of the dehumidifier (found with gaps-and-islands). */
CREATE TABLE dw.fact_dehumidifier_session
(
    session_start_utc datetime2(0)  NOT NULL,
    entity_id         varchar(255)  NOT NULL,
    session_end_utc   datetime2(0)  NULL,     -- NULL while it is still running
    start_date_key    int           NOT NULL,
    minutes_on        decimal(9, 2) NOT NULL,
    device_mode       nvarchar(40)  NULL,
    decision_mode     nvarchar(10)  NULL,
    humidity_start    decimal(5, 1) NULL,
    humidity_end      decimal(5, 1) NULL,
    is_complete       bit           NOT NULL,
    CONSTRAINT PK_fact_dehumidifier_session PRIMARY KEY CLUSTERED (session_start_utc, entity_id)
);
GO

/* Things that happened: bucket full, too hot, the automation changing its mind, auto on/off. */
CREATE TABLE dw.fact_event
(
    event_utc   datetime2(3)   NOT NULL,
    event_type  varchar(30)    NOT NULL,
    date_key    int            NOT NULL,
    detail      nvarchar(100)  NULL,
    CONSTRAINT PK_fact_event PRIMARY KEY CLUSTERED (event_utc, event_type)
);
GO
