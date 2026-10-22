/* Groups Iowa's ~50 liquor categories into a handful a reader can compare. Order matters:
   "Virgin Islands Rum" must be Rum before the Gin test, flavored vodkas stay Vodka, etc. */
CREATE FUNCTION dw.fn_category_group (@category_name nvarchar(100))
RETURNS varchar(30)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @n nvarchar(100) = UPPER(COALESCE(@category_name, N''));
    RETURN CASE
        WHEN @n = N'' THEN 'Unknown'
        WHEN @n LIKE N'%VODKA%' THEN 'Vodka'
        WHEN @n LIKE N'%WHISK%' OR @n LIKE N'%BOURBON%' OR @n LIKE N'%SCOTCH%' OR @n LIKE N'%RYE%' THEN 'Whiskey'
        WHEN @n LIKE N'%TEQUILA%' OR @n LIKE N'%MEZCAL%' THEN 'Tequila & Mezcal'
        WHEN @n LIKE N'%RUM%' THEN 'Rum'
        WHEN @n LIKE N'%BRAND%' OR @n LIKE N'%COGNAC%' THEN 'Brandy'
        WHEN @n LIKE N'%SCHNAPP%' THEN 'Schnapps'
        WHEN @n LIKE N'%LIQUEUR%' OR @n LIKE N'%CORDIAL%' OR @n LIKE N'%AMARETTO%' OR @n LIKE N'%CREME%'
             OR @n LIKE N'%TRIPLE SEC%' OR @n LIKE N'%ANISE%' THEN 'Liqueurs & Cordials'
        WHEN @n LIKE N'%COCKTAIL%' OR @n LIKE N'%RTD%' THEN 'Cocktails & RTD'
        WHEN @n LIKE N'%GIN%' THEN 'Gin'
        ELSE 'Other'
    END;
END;
GO
