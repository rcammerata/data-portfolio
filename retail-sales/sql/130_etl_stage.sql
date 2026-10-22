/* Receives one chunk of a month. @rows is a JSON array of arrays, one per sales line, in this
   column order (the loader, homebase/lib/portfolio_retail.py, builds it):
     0 invoice_line_no  1 sale_date  2 store_number  3 store_name  4 address  5 city  6 zip_code
     7 latitude  8 longitude  9 county  10 category_number  11 category_name  12 vendor_number
     13 vendor_name  14 item_number  15 item_description  16 pack  17 bottle_volume_ml
     18 state_bottle_cost  19 state_bottle_retail  20 bottles_sold  21 sale_dollars  22 volume_liters
   The first chunk of a month clears anything left over from an earlier, unfinished attempt. */
CREATE PROCEDURE etl.usp_stage_iowa
    @load_month  date,
    @rows        nvarchar(max),
    @first_chunk bit = 0,
    @result      nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@rows) <> 1
        THROW 50001, N'The rows are not valid JSON.', 1;

    DECLARE @month date = DATEFROMPARTS(YEAR(@load_month), MONTH(@load_month), 1);
    DECLARE @staged int;

    IF @first_chunk = 1
        DELETE FROM stg.iowa_sales WHERE load_month = @month;

    INSERT INTO stg.iowa_sales
        (load_month, invoice_line_no, sale_date, store_number, store_name, address, city, zip_code, latitude,
         longitude, county, category_number, category_name, vendor_number, vendor_name, item_number,
         item_description, pack, bottle_volume_ml, state_bottle_cost, state_bottle_retail, bottles_sold,
         sale_dollars, volume_liters)
    SELECT
        @month, j.invoice_line_no, j.sale_date, j.store_number, j.store_name, j.address, j.city, j.zip_code,
        j.latitude, j.longitude, j.county, j.category_number, j.category_name, j.vendor_number, j.vendor_name,
        j.item_number, j.item_description, j.pack, j.bottle_volume_ml, j.state_bottle_cost,
        j.state_bottle_retail, j.bottles_sold, j.sale_dollars, j.volume_liters
    FROM OPENJSON(@rows)
         WITH (
             invoice_line_no     varchar(40)    '$[0]',
             sale_date           date           '$[1]',
             store_number        int            '$[2]',
             store_name          nvarchar(200)  '$[3]',
             address             nvarchar(200)  '$[4]',
             city                nvarchar(100)  '$[5]',
             zip_code            varchar(10)    '$[6]',
             latitude            decimal(9, 6)  '$[7]',
             longitude           decimal(9, 6)  '$[8]',
             county              nvarchar(60)   '$[9]',
             category_number     int            '$[10]',
             category_name       nvarchar(100)  '$[11]',
             vendor_number       int            '$[12]',
             vendor_name         nvarchar(200)  '$[13]',
             item_number         varchar(20)    '$[14]',
             item_description    nvarchar(200)  '$[15]',
             pack                int            '$[16]',
             bottle_volume_ml    int            '$[17]',
             state_bottle_cost   decimal(10, 2) '$[18]',
             state_bottle_retail decimal(10, 2) '$[19]',
             bottles_sold        int            '$[20]',
             sale_dollars        decimal(12, 2) '$[21]',
             volume_liters       decimal(12, 2) '$[22]'
         ) AS j
    WHERE j.invoice_line_no IS NOT NULL
      AND j.sale_date >= @month
      AND j.sale_date < DATEADD(month, 1, @month);

    SET @staged = (SELECT COUNT(*) FROM stg.iowa_sales WHERE load_month = @month);
    SET @result = (SELECT CONVERT(char(10), @month, 23) AS load_month, @staged AS staged_rows
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
END;
GO
