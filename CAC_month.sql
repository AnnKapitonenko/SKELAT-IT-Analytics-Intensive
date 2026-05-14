WITH deduplicated_ads AS (
  SELECT *
  FROM (
    SELECT 
      *,
      ROW_NUMBER() OVER(
        PARTITION BY ad_id, date 
        ORDER BY timestamp DESC
      ) as rn
    FROM `my-project-sql-workshop-496104.workshop_sql.marketing_ads_raw`
  )
  WHERE rn = 1
),
daily_metrics AS (
  SELECT
    source,
    EXTRACT(MONTH FROM date) as date_month,
    sum(spend) AS daily_spend,
    SUM(impressions) AS daily_impr,
    SUM(clicks) AS daily_clicks,
    SUM(installs) AS daily_installs,
    SUM(registrations) AS daily_regs
  FROM deduplicated_ads
  GROUP BY 1, 2
)
SELECT
  source,
  date_month,
  ROUND(SAFE_DIVIDE(SUM(daily_spend), SUM(daily_regs)), 2) AS CAC
FROM daily_metrics
GROUP BY 1,2
ORDER BY source,date_month
