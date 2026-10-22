/* Retail sales: star schema. Dimensions keep the latest attributes seen (type 1); key -1 is
   the "Unknown" member for rows that arrive without a store, item, vendor, category or county. */

CREATE TABLE dw.dim_county
(
    county_key   int           IDENTITY(1, 1) NOT NULL,
    county_name  nvarchar(60)  NOT NULL,
    CONSTRAINT PK_dim_county PRIMARY KEY CLUSTERED (county_key),
    CONSTRAINT UQ_dim_county_name UNIQUE (county_name)
);
GO

CREATE TABLE dw.county_population
(
    county_key       int       NOT NULL,
    population_year  smallint  NOT NULL,
    population       int       NOT NULL,
    CONSTRAINT PK_county_population PRIMARY KEY CLUSTERED (county_key, population_year),
    CONSTRAINT FK_county_population_county FOREIGN KEY (county_key) REFERENCES dw.dim_county (county_key)
);
GO

CREATE TABLE dw.dim_store
(
    store_key        int            IDENTITY(1, 1) NOT NULL,
    store_number     int            NOT NULL,
    store_name       nvarchar(200)  NOT NULL,
    address          nvarchar(200)  NULL,
    city             nvarchar(100)  NULL,
    zip_code         varchar(10)    NULL,
    county_key       int            NOT NULL,
    latitude         decimal(9, 6)  NULL,
    longitude        decimal(9, 6)  NULL,
    first_sale_date  date           NULL,
    last_sale_date   date           NULL,
    CONSTRAINT PK_dim_store PRIMARY KEY CLUSTERED (store_key),
    CONSTRAINT UQ_dim_store_number UNIQUE (store_number)
);
GO

CREATE TABLE dw.dim_vendor
(
    vendor_key       int            IDENTITY(1, 1) NOT NULL,
    vendor_number    int            NOT NULL,
    vendor_name      nvarchar(200)  NOT NULL,
    first_sale_date  date           NULL,
    last_sale_date   date           NULL,
    CONSTRAINT PK_dim_vendor PRIMARY KEY CLUSTERED (vendor_key),
    CONSTRAINT UQ_dim_vendor_number UNIQUE (vendor_number)
);
GO

CREATE TABLE dw.dim_category
(
    category_key     int            IDENTITY(1, 1) NOT NULL,
    category_number  int            NOT NULL,
    category_name    nvarchar(100)  NOT NULL,
    category_group   varchar(30)    NOT NULL,
    last_sale_date   date           NULL,
    CONSTRAINT PK_dim_category PRIMARY KEY CLUSTERED (category_key),
    CONSTRAINT UQ_dim_category_number UNIQUE (category_number)
);
GO

CREATE TABLE dw.dim_item
(
    item_key          int            IDENTITY(1, 1) NOT NULL,
    item_number       varchar(20)    NOT NULL,
    item_description  nvarchar(200)  NOT NULL,
    pack              int            NULL,
    bottle_volume_ml  int            NULL,
    category_key      int            NOT NULL,
    vendor_key        int            NOT NULL,
    last_bottle_retail decimal(10, 2) NULL,
    first_sale_date   date           NULL,
    last_sale_date    date           NULL,
    CONSTRAINT PK_dim_item PRIMARY KEY CLUSTERED (item_key),
    CONSTRAINT UQ_dim_item_number UNIQUE (item_number)
);
GO

/* Grain: one invoice line (one item on one store order). A clustered columnstore index keeps
   millions of rows small and makes month/category/vendor aggregations fast. */
CREATE TABLE dw.fact_sales
(
    invoice_line_no      varchar(40)    NOT NULL,
    date_key             int            NOT NULL,
    store_key            int            NOT NULL,
    item_key             int            NOT NULL,
    vendor_key           int            NOT NULL,
    category_key         int            NOT NULL,
    county_key           int            NOT NULL,
    bottles_sold         int            NOT NULL,
    sale_dollars         decimal(12, 2) NOT NULL,
    volume_liters        decimal(12, 2) NOT NULL,
    state_bottle_cost    decimal(10, 2) NOT NULL,
    state_bottle_retail  decimal(10, 2) NOT NULL
);
GO

CREATE CLUSTERED COLUMNSTORE INDEX CCI_fact_sales ON dw.fact_sales;
GO

/* One row per loaded month: what arrived, what was kept, and when. */
CREATE TABLE dw.load_log
(
    load_month     date          NOT NULL,
    source_rows    int           NOT NULL,
    rows_loaded    int           NOT NULL,
    duplicate_rows int           NOT NULL,
    loaded_utc     datetime2(0)  NOT NULL,
    CONSTRAINT PK_load_log PRIMARY KEY CLUSTERED (load_month)
);
GO
