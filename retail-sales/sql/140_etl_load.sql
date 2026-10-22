/* Moves one staged month into the star schema, in one transaction:
     1. check the staged row count against what was downloaded
     2. add new counties, stores, vendors, categories and items; refresh their attributes when this
        month is the newest seen for them (type 1 dimensions)
     3. replace the month's fact rows (so reloading a month is safe), dropping duplicate lines
     4. record the load in dw.load_log and clear the staging rows */
CREATE PROCEDURE etl.usp_load_iowa_month
    @load_month    date,
    @expected_rows int,
    @result        nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @month date = DATEFROMPARTS(YEAR(@load_month), MONTH(@load_month), 1);
    DECLARE @month_end date = EOMONTH(@month);
    DECLARE @first_key int = YEAR(@month) * 10000 + MONTH(@month) * 100 + 1;
    DECLARE @last_key int = YEAR(@month_end) * 10000 + MONTH(@month_end) * 100 + DAY(@month_end);
    DECLARE @staged int = (SELECT COUNT(*) FROM stg.iowa_sales WHERE load_month = @month);
    DECLARE @loaded int = 0;

    IF @staged <> @expected_rows
        THROW 50020, N'The staged row count does not match the download, so the month was not loaded.', 1;

    EXEC etl.usp_ensure_dates @from = @month, @to = @month_end;

    ------------------------------------------------------------------ latest attributes per key
    CREATE TABLE #store
    (
        store_number int           NOT NULL PRIMARY KEY,
        store_name   nvarchar(200) NULL,
        address      nvarchar(200) NULL,
        city         nvarchar(100) NULL,
        zip_code     varchar(10)   NULL,
        county       nvarchar(60)  NULL,
        latitude     decimal(9, 6) NULL,
        longitude    decimal(9, 6) NULL,
        first_date   date          NOT NULL,
        last_date    date          NOT NULL
    );

    INSERT INTO #store (store_number, store_name, address, city, zip_code, county, latitude, longitude, first_date, last_date)
    SELECT r.store_number, r.store_name, r.address, r.city, r.zip_code, r.county, r.latitude, r.longitude, r.first_date, r.last_date
    FROM (
        SELECT
            s.store_number, s.store_name, s.address, s.city, s.zip_code, s.county, s.latitude, s.longitude,
            MIN(s.sale_date) OVER (PARTITION BY s.store_number) AS first_date,
            MAX(s.sale_date) OVER (PARTITION BY s.store_number) AS last_date,
            ROW_NUMBER() OVER (PARTITION BY s.store_number ORDER BY s.sale_date DESC, s.invoice_line_no DESC) AS rn
        FROM stg.iowa_sales AS s
        WHERE s.load_month = @month AND s.store_number IS NOT NULL
    ) AS r
    WHERE r.rn = 1;

    CREATE TABLE #vendor
    (
        vendor_number int           NOT NULL PRIMARY KEY,
        vendor_name   nvarchar(200) NULL,
        first_date    date          NOT NULL,
        last_date     date          NOT NULL
    );

    INSERT INTO #vendor (vendor_number, vendor_name, first_date, last_date)
    SELECT r.vendor_number, r.vendor_name, r.first_date, r.last_date
    FROM (
        SELECT
            s.vendor_number, s.vendor_name,
            MIN(s.sale_date) OVER (PARTITION BY s.vendor_number) AS first_date,
            MAX(s.sale_date) OVER (PARTITION BY s.vendor_number) AS last_date,
            ROW_NUMBER() OVER (PARTITION BY s.vendor_number ORDER BY s.sale_date DESC, s.invoice_line_no DESC) AS rn
        FROM stg.iowa_sales AS s
        WHERE s.load_month = @month AND s.vendor_number IS NOT NULL
    ) AS r
    WHERE r.rn = 1;

    CREATE TABLE #category
    (
        category_number int           NOT NULL PRIMARY KEY,
        category_name   nvarchar(100) NULL,
        last_date       date          NOT NULL
    );

    INSERT INTO #category (category_number, category_name, last_date)
    SELECT r.category_number, r.category_name, r.last_date
    FROM (
        SELECT
            s.category_number, s.category_name,
            MAX(s.sale_date) OVER (PARTITION BY s.category_number) AS last_date,
            ROW_NUMBER() OVER (PARTITION BY s.category_number ORDER BY s.sale_date DESC, s.invoice_line_no DESC) AS rn
        FROM stg.iowa_sales AS s
        WHERE s.load_month = @month AND s.category_number IS NOT NULL
    ) AS r
    WHERE r.rn = 1;

    CREATE TABLE #item
    (
        item_number       varchar(20)    NOT NULL PRIMARY KEY,
        item_description  nvarchar(200)  NULL,
        pack              int            NULL,
        bottle_volume_ml  int            NULL,
        category_number   int            NULL,
        vendor_number     int            NULL,
        bottle_retail     decimal(10, 2) NULL,
        first_date        date           NOT NULL,
        last_date         date           NOT NULL
    );

    INSERT INTO #item (item_number, item_description, pack, bottle_volume_ml, category_number, vendor_number,
                       bottle_retail, first_date, last_date)
    SELECT r.item_number, r.item_description, r.pack, r.bottle_volume_ml, r.category_number, r.vendor_number,
           r.state_bottle_retail, r.first_date, r.last_date
    FROM (
        SELECT
            s.item_number, s.item_description, s.pack, s.bottle_volume_ml, s.category_number, s.vendor_number,
            s.state_bottle_retail,
            MIN(s.sale_date) OVER (PARTITION BY s.item_number) AS first_date,
            MAX(s.sale_date) OVER (PARTITION BY s.item_number) AS last_date,
            ROW_NUMBER() OVER (PARTITION BY s.item_number ORDER BY s.sale_date DESC, s.invoice_line_no DESC) AS rn
        FROM stg.iowa_sales AS s
        WHERE s.load_month = @month AND s.item_number IS NOT NULL
    ) AS r
    WHERE r.rn = 1;

    BEGIN TRANSACTION;

    ------------------------------------------------------------------ dimensions
    INSERT INTO dw.dim_county (county_name)
    SELECT DISTINCT s.county
    FROM stg.iowa_sales AS s
    WHERE s.load_month = @month
      AND s.county IS NOT NULL
      AND s.county <> N''
      AND NOT EXISTS (SELECT 1 FROM dw.dim_county AS c WHERE c.county_name = s.county);

    UPDATE d
    SET d.store_name = COALESCE(s.store_name, d.store_name),
        d.address = COALESCE(s.address, d.address),
        d.city = COALESCE(s.city, d.city),
        d.zip_code = COALESCE(s.zip_code, d.zip_code),
        d.county_key = COALESCE(c.county_key, d.county_key),
        d.latitude = COALESCE(s.latitude, d.latitude),
        d.longitude = COALESCE(s.longitude, d.longitude)
    FROM dw.dim_store AS d
    JOIN #store AS s ON s.store_number = d.store_number
    LEFT JOIN dw.dim_county AS c ON c.county_name = s.county
    WHERE s.last_date >= COALESCE(d.last_sale_date, CONVERT(date, '19000101'));

    UPDATE d
    SET d.first_sale_date = LEAST(COALESCE(d.first_sale_date, s.first_date), s.first_date),
        d.last_sale_date = GREATEST(COALESCE(d.last_sale_date, s.last_date), s.last_date)
    FROM dw.dim_store AS d
    JOIN #store AS s ON s.store_number = d.store_number;

    INSERT INTO dw.dim_store (store_number, store_name, address, city, zip_code, county_key, latitude, longitude,
                              first_sale_date, last_sale_date)
    SELECT s.store_number, COALESCE(s.store_name, CONCAT(N'Store ', s.store_number)), s.address, s.city, s.zip_code,
           COALESCE(c.county_key, -1), s.latitude, s.longitude, s.first_date, s.last_date
    FROM #store AS s
    LEFT JOIN dw.dim_county AS c ON c.county_name = s.county
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_store AS d WHERE d.store_number = s.store_number);

    UPDATE d
    SET d.vendor_name = COALESCE(s.vendor_name, d.vendor_name)
    FROM dw.dim_vendor AS d
    JOIN #vendor AS s ON s.vendor_number = d.vendor_number
    WHERE s.last_date >= COALESCE(d.last_sale_date, CONVERT(date, '19000101'));

    UPDATE d
    SET d.first_sale_date = LEAST(COALESCE(d.first_sale_date, s.first_date), s.first_date),
        d.last_sale_date = GREATEST(COALESCE(d.last_sale_date, s.last_date), s.last_date)
    FROM dw.dim_vendor AS d
    JOIN #vendor AS s ON s.vendor_number = d.vendor_number;

    INSERT INTO dw.dim_vendor (vendor_number, vendor_name, first_sale_date, last_sale_date)
    SELECT s.vendor_number, COALESCE(s.vendor_name, CONCAT(N'Vendor ', s.vendor_number)), s.first_date, s.last_date
    FROM #vendor AS s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_vendor AS d WHERE d.vendor_number = s.vendor_number);

    UPDATE d
    SET d.category_name = COALESCE(s.category_name, d.category_name),
        d.category_group = dw.fn_category_group(COALESCE(s.category_name, d.category_name)),
        d.last_sale_date = s.last_date
    FROM dw.dim_category AS d
    JOIN #category AS s ON s.category_number = d.category_number
    WHERE s.last_date >= COALESCE(d.last_sale_date, CONVERT(date, '19000101'));

    INSERT INTO dw.dim_category (category_number, category_name, category_group, last_sale_date)
    SELECT s.category_number, COALESCE(s.category_name, CONCAT(N'Category ', s.category_number)),
           dw.fn_category_group(s.category_name), s.last_date
    FROM #category AS s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_category AS d WHERE d.category_number = s.category_number);

    UPDATE d
    SET d.item_description = COALESCE(s.item_description, d.item_description),
        d.pack = COALESCE(s.pack, d.pack),
        d.bottle_volume_ml = COALESCE(s.bottle_volume_ml, d.bottle_volume_ml),
        d.category_key = COALESCE(c.category_key, d.category_key),
        d.vendor_key = COALESCE(v.vendor_key, d.vendor_key),
        d.last_bottle_retail = COALESCE(s.bottle_retail, d.last_bottle_retail)
    FROM dw.dim_item AS d
    JOIN #item AS s ON s.item_number = d.item_number
    LEFT JOIN dw.dim_category AS c ON c.category_number = s.category_number
    LEFT JOIN dw.dim_vendor AS v ON v.vendor_number = s.vendor_number
    WHERE s.last_date >= COALESCE(d.last_sale_date, CONVERT(date, '19000101'));

    UPDATE d
    SET d.first_sale_date = LEAST(COALESCE(d.first_sale_date, s.first_date), s.first_date),
        d.last_sale_date = GREATEST(COALESCE(d.last_sale_date, s.last_date), s.last_date)
    FROM dw.dim_item AS d
    JOIN #item AS s ON s.item_number = d.item_number;

    INSERT INTO dw.dim_item (item_number, item_description, pack, bottle_volume_ml, category_key, vendor_key,
                             last_bottle_retail, first_sale_date, last_sale_date)
    SELECT s.item_number, COALESCE(s.item_description, CONCAT(N'Item ', s.item_number)), s.pack, s.bottle_volume_ml,
           COALESCE(c.category_key, -1), COALESCE(v.vendor_key, -1), s.bottle_retail, s.first_date, s.last_date
    FROM #item AS s
    LEFT JOIN dw.dim_category AS c ON c.category_number = s.category_number
    LEFT JOIN dw.dim_vendor AS v ON v.vendor_number = s.vendor_number
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_item AS d WHERE d.item_number = s.item_number);

    ------------------------------------------------------------------ facts
    DELETE FROM dw.fact_sales WHERE date_key BETWEEN @first_key AND @last_key;

    WITH deduplicated AS
    (
        SELECT
            s.invoice_line_no, s.sale_date, s.store_number, s.item_number, s.vendor_number, s.category_number,
            s.county, s.bottles_sold, s.sale_dollars, s.volume_liters, s.state_bottle_cost, s.state_bottle_retail,
            ROW_NUMBER() OVER (PARTITION BY s.invoice_line_no ORDER BY s.sale_date DESC) AS rn
        FROM stg.iowa_sales AS s
        WHERE s.load_month = @month
    )
    INSERT INTO dw.fact_sales
        (invoice_line_no, date_key, store_key, item_key, vendor_key, category_key, county_key, bottles_sold,
         sale_dollars, volume_liters, state_bottle_cost, state_bottle_retail)
    SELECT
        x.invoice_line_no,
        YEAR(x.sale_date) * 10000 + MONTH(x.sale_date) * 100 + DAY(x.sale_date),
        COALESCE(st.store_key, -1),
        COALESCE(it.item_key, -1),
        COALESCE(v.vendor_key, -1),
        COALESCE(ca.category_key, -1),
        COALESCE(co.county_key, -1),
        COALESCE(x.bottles_sold, 0),
        COALESCE(x.sale_dollars, 0),
        COALESCE(x.volume_liters, 0),
        COALESCE(x.state_bottle_cost, 0),
        COALESCE(x.state_bottle_retail, 0)
    FROM deduplicated AS x
    LEFT JOIN dw.dim_store AS st ON st.store_number = x.store_number
    LEFT JOIN dw.dim_item AS it ON it.item_number = x.item_number
    LEFT JOIN dw.dim_vendor AS v ON v.vendor_number = x.vendor_number
    LEFT JOIN dw.dim_category AS ca ON ca.category_number = x.category_number
    LEFT JOIN dw.dim_county AS co ON co.county_name = x.county
    WHERE x.rn = 1;
    SET @loaded = @@ROWCOUNT;

    UPDATE dw.load_log
    SET source_rows = @staged, rows_loaded = @loaded, duplicate_rows = @staged - @loaded, loaded_utc = SYSUTCDATETIME()
    WHERE load_month = @month;

    IF @@ROWCOUNT = 0
        INSERT INTO dw.load_log (load_month, source_rows, rows_loaded, duplicate_rows, loaded_utc)
        VALUES (@month, @staged, @loaded, @staged - @loaded, SYSUTCDATETIME());

    DELETE FROM stg.iowa_sales WHERE load_month = @month;

    COMMIT TRANSACTION;

    SET @result = (
        SELECT CONVERT(char(10), @month, 23) AS load_month, @staged AS source_rows, @loaded AS rows_loaded,
               @staged - @loaded AS duplicate_rows
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );
END;
GO

/* The months already loaded, newest first (the loader reloads the latest two each month,
   because the state sometimes corrects recent data). */
CREATE PROCEDURE etl.usp_get_loaded_months
    @result nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET @result = COALESCE((
        SELECT CONVERT(char(10), l.load_month, 23) AS load_month, l.rows_loaded,
               CONVERT(varchar(19), l.loaded_utc, 126) AS loaded_utc
        FROM dw.load_log AS l
        ORDER BY l.load_month DESC
        FOR JSON PATH
    ), N'[]');
END;
GO

/* County population by year (a second public dataset), for sales per person.
   Payload: [{"county": "Polk", "year": 2024, "population": 500000}, ...] */
CREATE PROCEDURE etl.usp_load_population
    @payload nvarchar(max),
    @result  nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@payload) <> 1
        THROW 50001, N'The payload is not valid JSON.', 1;

    CREATE TABLE #pop
    (
        county_name     nvarchar(60) NOT NULL,
        population_year smallint     NOT NULL,
        population      int          NOT NULL
    );

    INSERT INTO #pop (county_name, population_year, population)
    SELECT j.county_name, j.population_year, MAX(j.population)
    FROM OPENJSON(@payload)
         WITH (
             county_name     nvarchar(60) '$.county',
             population_year smallint     '$.year',
             population      int          '$.population'
         ) AS j
    WHERE j.county_name IS NOT NULL AND j.population_year IS NOT NULL AND j.population > 0
    GROUP BY j.county_name, j.population_year;

    BEGIN TRANSACTION;

    INSERT INTO dw.dim_county (county_name)
    SELECT DISTINCT p.county_name
    FROM #pop AS p
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_county AS c WHERE c.county_name = p.county_name);

    UPDATE cp
    SET cp.population = p.population
    FROM dw.county_population AS cp
    JOIN dw.dim_county AS c ON c.county_key = cp.county_key
    JOIN #pop AS p ON p.county_name = c.county_name AND p.population_year = cp.population_year;

    INSERT INTO dw.county_population (county_key, population_year, population)
    SELECT c.county_key, p.population_year, p.population
    FROM #pop AS p
    JOIN dw.dim_county AS c ON c.county_name = p.county_name
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.county_population AS cp
        WHERE cp.county_key = c.county_key AND cp.population_year = p.population_year
    );

    COMMIT TRANSACTION;

    SET @result = (SELECT COUNT(*) AS population_rows FROM dw.county_population FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
END;
GO
