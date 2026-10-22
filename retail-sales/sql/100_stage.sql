/*
  Retail sales (Iowa liquor sales, public domain): staging.
  The loader downloads one month at a time from data.iowa.gov and sends it here in chunks;
  etl.usp_load_iowa_month then moves the month into the star schema in one transaction.
*/
CREATE SCHEMA stg AUTHORIZATION dbo;
GO

CREATE TABLE stg.iowa_sales
(
    load_month          date           NOT NULL,
    invoice_line_no     varchar(40)    NOT NULL,
    sale_date           date           NOT NULL,
    store_number        int            NULL,
    store_name          nvarchar(200)  NULL,
    address             nvarchar(200)  NULL,
    city                nvarchar(100)  NULL,
    zip_code            varchar(10)    NULL,
    latitude            decimal(9, 6)  NULL,
    longitude           decimal(9, 6)  NULL,
    county              nvarchar(60)   NULL,
    category_number     int            NULL,
    category_name       nvarchar(100)  NULL,
    vendor_number       int            NULL,
    vendor_name         nvarchar(200)  NULL,
    item_number         varchar(20)    NULL,
    item_description    nvarchar(200)  NULL,
    pack                int            NULL,
    bottle_volume_ml    int            NULL,
    state_bottle_cost   decimal(10, 2) NULL,
    state_bottle_retail decimal(10, 2) NULL,
    bottles_sold        int            NULL,
    sale_dollars        decimal(12, 2) NULL,
    volume_liters       decimal(12, 2) NULL
);
GO

CREATE CLUSTERED INDEX CX_stg_iowa_sales ON stg.iowa_sales (load_month, invoice_line_no);
GO
