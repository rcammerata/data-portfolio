/* Calendar dimension: one row per day. Weeks start on Monday; seasons are meteorological
   (northern hemisphere). Names come from CHOOSE so they don't depend on the login's language. */
CREATE TABLE dw.dim_date
(
    date_key        int          NOT NULL,   -- yyyymmdd
    calendar_date   date         NOT NULL,
    calendar_year   smallint     NOT NULL,
    quarter_number  tinyint      NOT NULL,
    quarter_label   char(2)      NOT NULL,   -- Q1..Q4
    month_number    tinyint      NOT NULL,
    month_name      varchar(9)   NOT NULL,
    month_short     char(3)      NOT NULL,
    year_month      char(7)      NOT NULL,   -- 2026-10
    month_start     date         NOT NULL,
    day_of_month    tinyint      NOT NULL,
    day_of_week     tinyint      NOT NULL,   -- 1 = Monday ... 7 = Sunday
    day_name        varchar(9)   NOT NULL,
    day_short       char(3)      NOT NULL,
    is_weekend      bit          NOT NULL,
    iso_week        tinyint      NOT NULL,
    week_start      date         NOT NULL,   -- the Monday of that week
    season          varchar(6)   NOT NULL,
    CONSTRAINT PK_dim_date PRIMARY KEY CLUSTERED (date_key),
    CONSTRAINT UQ_dim_date_calendar_date UNIQUE (calendar_date)
);
GO

/* Adds any missing days between @from and @to (inclusive). Safe to call repeatedly. */
CREATE PROCEDURE etl.usp_ensure_dates
    @from date,
    @to   date
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF @from IS NULL OR @to IS NULL OR @to < @from
        RETURN;

    INSERT INTO dw.dim_date
        (date_key, calendar_date, calendar_year, quarter_number, quarter_label, month_number, month_name,
         month_short, year_month, month_start, day_of_month, day_of_week, day_name, day_short, is_weekend,
         iso_week, week_start, season)
    SELECT
        YEAR(x.d) * 10000 + MONTH(x.d) * 100 + DAY(x.d),
        x.d,
        YEAR(x.d),
        DATEPART(quarter, x.d),
        CONCAT('Q', DATEPART(quarter, x.d)),
        MONTH(x.d),
        CHOOSE(MONTH(x.d), 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
               'September', 'October', 'November', 'December'),
        CHOOSE(MONTH(x.d), 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'),
        CONCAT(YEAR(x.d), '-', RIGHT(CONCAT('0', MONTH(x.d)), 2)),
        DATEFROMPARTS(YEAR(x.d), MONTH(x.d), 1),
        DAY(x.d),
        w.dow,
        CHOOSE(w.dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
        CHOOSE(w.dow, 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'),
        CASE WHEN w.dow >= 6 THEN 1 ELSE 0 END,
        DATEPART(iso_week, x.d),
        DATEADD(day, 1 - w.dow, x.d),
        CASE WHEN MONTH(x.d) IN (12, 1, 2) THEN 'Winter'
             WHEN MONTH(x.d) IN (3, 4, 5) THEN 'Spring'
             WHEN MONTH(x.d) IN (6, 7, 8) THEN 'Summer'
             ELSE 'Fall' END
    FROM GENERATE_SERIES(0, DATEDIFF(day, @from, @to)) AS g
    CROSS APPLY (SELECT DATEADD(day, g.value, @from) AS d) AS x
    -- 1900-01-01 was a Monday, so this gives 1 = Monday regardless of SET DATEFIRST.
    CROSS APPLY (SELECT CONVERT(tinyint, DATEDIFF(day, CONVERT(date, '19000101'), x.d) % 7 + 1) AS dow) AS w
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date AS dd WHERE dd.calendar_date = x.d);
END;
GO
