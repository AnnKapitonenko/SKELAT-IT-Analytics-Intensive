-- КРОК 1: Дедублікація (залишаємо останній snapshot за кожен день для кожного оголошення)
WITH deduplicated_ads AS (
  SELECT *
  FROM (
    SELECT 
      *,
      -- Створюємо номер рядка для кожного оголошення на конкретну дату
      -- Сортуємо за часом (timestamp) у зворотньому порядку, щоб взяти найновіший запис
      ROW_NUMBER() OVER(
        PARTITION BY ad_id, date 
        ORDER BY timestamp DESC
      ) as rn
    FROM `my-project-sql-workshop-496104.workshop_sql.marketing_ads_raw`
  )
  WHERE rn = 1
),

-- КРОК 2: Денні метрики по каналах
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

-- КРОК 3: Фінальні метрики за весь період (згідно з image_58beb3.png)
SELECT
  source,
  date_month,
  -- 6. CAC: Витрати / Реєстрації (вартість одного підписника)
  ROUND(SAFE_DIVIDE(SUM(daily_spend), SUM(daily_regs)), 2) AS CAC
FROM daily_metrics
GROUP BY 1,2
ORDER BY source,date_month