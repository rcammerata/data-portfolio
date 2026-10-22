/* Defaults and the "Unknown" members; the deploy tool runs this after every deployment. */
CREATE PROCEDURE etl.usp_post_deploy
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @report_from nvarchar(200) = CONVERT(nvarchar(10), DATEFROMPARTS(YEAR(SYSUTCDATETIME()) - 3, 1, 1), 23);
    EXEC etl.usp_default_setting 'report_from', @report_from,
        N'Power BI imports sales from this day on (the database keeps more).';
    EXEC etl.usp_default_setting 'calendar_from', @report_from, N'First day of the Power BI calendar.';
    EXEC etl.usp_default_setting 'time_zone', N'UTC', N'Not used by this project (sales have no time of day).';

    IF NOT EXISTS (SELECT 1 FROM dw.dim_county WHERE county_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_county ON;
        INSERT INTO dw.dim_county (county_key, county_name) VALUES (-1, N'Unknown');
        SET IDENTITY_INSERT dw.dim_county OFF;
    END;

    IF NOT EXISTS (SELECT 1 FROM dw.dim_store WHERE store_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_store ON;
        INSERT INTO dw.dim_store (store_key, store_number, store_name, county_key) VALUES (-1, -1, N'Unknown store', -1);
        SET IDENTITY_INSERT dw.dim_store OFF;
    END;

    IF NOT EXISTS (SELECT 1 FROM dw.dim_vendor WHERE vendor_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_vendor ON;
        INSERT INTO dw.dim_vendor (vendor_key, vendor_number, vendor_name) VALUES (-1, -1, N'Unknown vendor');
        SET IDENTITY_INSERT dw.dim_vendor OFF;
    END;

    IF NOT EXISTS (SELECT 1 FROM dw.dim_category WHERE category_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_category ON;
        INSERT INTO dw.dim_category (category_key, category_number, category_name, category_group)
        VALUES (-1, -1, N'Unknown category', 'Unknown');
        SET IDENTITY_INSERT dw.dim_category OFF;
    END;

    IF NOT EXISTS (SELECT 1 FROM dw.dim_item WHERE item_key = -1)
    BEGIN
        SET IDENTITY_INSERT dw.dim_item ON;
        INSERT INTO dw.dim_item (item_key, item_number, item_description, category_key, vendor_key)
        VALUES (-1, '-1', N'Unknown item', -1, -1);
        SET IDENTITY_INSERT dw.dim_item OFF;
    END;

    DECLARE @first_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) - 3, 1, 1);
    DECLARE @last_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) + 1, 12, 31);
    EXEC etl.usp_ensure_dates @from = @first_day, @to = @last_day;
END;
GO

/* Nightly housekeeping (scheduled as a SQL Server Agent job): compress the columnstore after
   month reloads (removes deleted rows) and refresh statistics. */
CREATE PROCEDURE etl.usp_nightly_maintenance
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @last_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()) + 1, 12, 31);
    DECLARE @first_day date = DATEFROMPARTS(YEAR(SYSUTCDATETIME()), 1, 1);
    EXEC etl.usp_ensure_dates @from = @first_day, @to = @last_day;

    ALTER INDEX CCI_fact_sales ON dw.fact_sales REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

    UPDATE STATISTICS dw.dim_store;
    UPDATE STATISTICS dw.dim_item;
    UPDATE STATISTICS dw.dim_vendor;
    UPDATE STATISTICS dw.dim_category;
END;
GO
