/* The states of one entity in [@from_utc, @to_utc), plus the state it was already in at
   @from_utc (its latest earlier state), so every transform knows how a window starts. */
CREATE FUNCTION dw.tvf_entity_states
(
    @entity_id varchar(255),
    @from_utc  datetime2(3),
    @to_utc    datetime2(3)
)
RETURNS TABLE
AS
RETURN
(
    SELECT s.entity_id, s.state, s.attributes, s.last_updated
    FROM raw.ha_state AS s
    WHERE s.entity_id = @entity_id
      AND s.last_updated >= @from_utc
      AND s.last_updated < @to_utc
    UNION ALL
    SELECT p.entity_id, p.state, p.attributes, p.last_updated
    FROM (
        SELECT TOP (1) s2.entity_id, s2.state, s2.attributes, s2.last_updated
        FROM raw.ha_state AS s2
        WHERE s2.entity_id = @entity_id
          AND s2.last_updated < @from_utc
        ORDER BY s2.last_updated DESC
    ) AS p
);
GO
