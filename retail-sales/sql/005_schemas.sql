/*
  Shared objects, deployed into every portfolio database before its own objects.

  Schemas (a small "medallion" layout):
    dw   cleaned star schema: dimensions and facts
    etl  the procedures the loaders call; the etl login may run these and nothing else
    rpt  views Power BI reads; the powerbi login may read these and nothing else
    pub  small, rounded summaries that are published on the public portfolio page

  Deployment convention (homebase/bin/portfolio sql deploy): batches are separated by GO and
  each batch holds exactly one CREATE statement. The deploy tool makes them safe to re-run
  (CREATE OR ALTER for views and procedures, "if missing" for schemas, tables and indexes).
*/
CREATE SCHEMA dw AUTHORIZATION dbo;
GO
CREATE SCHEMA etl AUTHORIZATION dbo;
GO
CREATE SCHEMA rpt AUTHORIZATION dbo;
GO
CREATE SCHEMA pub AUTHORIZATION dbo;
GO
