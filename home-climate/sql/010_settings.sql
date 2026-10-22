/* Settings the pipelines and views read (time zone, assumptions, publishing delay). */
CREATE TABLE dw.setting
(
    setting_key   varchar(60)    NOT NULL,
    setting_value nvarchar(200)  NOT NULL,
    description   nvarchar(400)  NULL,
    updated_utc   datetime2(0)   NOT NULL CONSTRAINT DF_setting_updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_setting PRIMARY KEY CLUSTERED (setting_key)
);
GO

/* Insert a setting if it is missing (used for defaults; never overwrites a value). */
CREATE PROCEDURE etl.usp_default_setting
    @setting_key   varchar(60),
    @setting_value nvarchar(200),
    @description   nvarchar(400) = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dw.setting WHERE setting_key = @setting_key)
        INSERT INTO dw.setting (setting_key, setting_value, description)
        VALUES (@setting_key, @setting_value, @description);
END;
GO

/* Change a setting. The time zone must be a name SQL Server knows (sys.time_zone_info). */
CREATE PROCEDURE etl.usp_set_setting
    @setting_key   varchar(60),
    @setting_value nvarchar(200),
    @result        nvarchar(max) = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF @setting_key = 'time_zone'
       AND NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @setting_value)
        THROW 50010, N'Unknown time zone name (see sys.time_zone_info).', 1;

    UPDATE dw.setting
    SET setting_value = @setting_value, updated_utc = SYSUTCDATETIME()
    WHERE setting_key = @setting_key;

    IF @@ROWCOUNT = 0
        INSERT INTO dw.setting (setting_key, setting_value) VALUES (@setting_key, @setting_value);

    SET @result = (SELECT @setting_key AS setting_key, @setting_value AS setting_value
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
END;
GO
