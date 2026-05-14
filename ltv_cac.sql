-- CTE 1: Визначаємо канал та дату інсталу для кожного юзера
WITH user_attribution AS (
  SELECT 
    user_id, 
    channel,
    MIN(timestamp) AS install_ts -- фіксуємо дату інсталу для відсікання ребілів (вікно 180 днів)
  FROM `cool-furnace-495912-n0.workshop_sql.product_events`
  WHERE event_type = 'install'
  GROUP BY 1, 2
),

-- CTE 2: Знаходимо юзерів, які бачили пейвол
paywall_users AS (
  SELECT DISTINCT user_id 
  FROM `cool-furnace-495912-n0.workshop_sql.product_events`
  WHERE event_type = 'paywall_view'
),

-- CTE 3: Агрегуємо дані по замовленнях (перша покупка, ребіли, апсейли)
order_stats AS (
  SELECT 
    o.user_id,
    -- ANY_VALUE з HAVING MIN дістає суму саме першої транзакції
    ANY_VALUE(o.amount HAVING MIN o.timestamp) AS first_payment_amount,
    -- Рахуємо ребіли протягом 180 днів від дати інсталу (ua.install_ts)
    COUNTIF(o.event = 'rebill' AND TIMESTAMP_DIFF(o.timestamp, ua.install_ts, DAY) <= 180) AS rebills_6m,
    -- Сума ребілів для подальшого розрахунку середнього чеку ребіла
    SUM(IF(o.event = 'rebill', o.amount, 0)) AS total_rebill_amount,
    -- Кількість та сума апсейлів
    COUNTIF(o.event = 'upsell') AS upsell_count,
    SUM(IF(o.event = 'upsell', o.amount, 0)) AS total_upsell_amount,
    -- Вважаємо юзера підписником, якщо є хоча б одна подія purchase
    COUNTIF(o.event = 'purchase') > 0 AS is_subscriber
  FROM `cool-furnace-495912-n0.workshop_sql.orders` o
  JOIN user_attribution ua ON o.user_id = ua.user_id -- JOIN для доступу до дати інсталу
  GROUP BY 1, ua.install_ts
),

-- CTE 4: Розрахунок проміжних метрик для фінальної формули LTV
metrics_calculation AS (
  SELECT 
      ua.channel,
      -- Конверсії
      ROUND(SAFE_DIVIDE(COUNT(DISTINCT pw.user_id), COUNT(DISTINCT ua.user_id)) * 100, 2) AS conv_install_paywall_pct,
      ROUND(SAFE_DIVIDE(COUNT(DISTINCT os.user_id), COUNT(DISTINCT pw.user_id)) * 100, 2) AS conv_paywall_purchase_pct,
      ROUND(SAFE_DIVIDE(COUNT(DISTINCT os.user_id), COUNT(DISTINCT ua.user_id)) * 100, 2) AS conv_install_purchase_pct,
      
      -- Показники для LTV
      SAFE_DIVIDE(SUM(os.rebills_6m), COUNT(DISTINCT os.user_id)) AS rebills_per_payer_6m,
      SAFE_DIVIDE(COUNT(DISTINCT IF(os.upsell_count > 0, os.user_id, NULL)), COUNT(DISTINCT IF(os.is_subscriber, os.user_id, NULL))) AS cr_sub_upsell_raw,
      AVG(os.first_payment_amount) AS firstAOV,
      SAFE_DIVIDE(SUM(os.total_rebill_amount), NULLIF(SUM(os.rebills_6m), 0)) AS rebillAOV,
      SAFE_DIVIDE(SUM(os.total_upsell_amount), NULLIF(SUM(os.upsell_count), 0)) AS upsellAOV
  FROM user_attribution ua
  LEFT JOIN paywall_users pw ON ua.user_id = pw.user_id -- LEFT JOIN щоб не втратити юзерів без подій
  LEFT JOIN order_stats os ON ua.user_id = os.user_id
  GROUP BY 1
)
,
deduplicated_ads as
(SELECT * ,
       row_number() over (partition by ad_id,date order by timestamp desc) as rn
FROM `my-project-sql-workshop-496104.workshop_sql.marketing_ads_raw`
),

daily_metrics as
(select 
  source, 
  date,
  SUM(spend) AS daily_spend,
  SUM(impressions) AS daily_impressions,
  SUM(clicks) AS daily_clicks,
  SUM(installs) AS daily_installs,
  SUM(registrations) AS daily_registrations
from deduplicated_ads
where rn=1
GROUP BY 1, 2),

metrics_by_channel as 
(
  SELECT
  source as channel,
  -- 1. Загальні витрати
  ROUND(SUM(daily_spend), 2) AS total_spend,
  
  -- 2. CPM: (Витрати / Покази) * 1000
  ROUND(SAFE_DIVIDE(SUM(daily_spend), SUM(daily_impressions)) * 1000, 2) AS cpm,
  
  -- 3. CTR: (Кліки / Покази) * 100%
  ROUND(SAFE_DIVIDE(SUM(daily_clicks), SUM(daily_impressions)) * 100, 2) AS ctr_pct,
  
  -- 4. CR Click→Install: (Встановлення / Кліки) * 100%
  ROUND(SAFE_DIVIDE(SUM(daily_installs), SUM(daily_clicks)) * 100, 2) AS cr_click_install_pct,
  
  -- 5. CR Install→Reg: (Реєстрації / Встановлення) * 100%
  ROUND(SAFE_DIVIDE(SUM(daily_registrations), SUM(daily_installs)) * 100, 2) AS cr_install_reg_pct,
  
  -- 6. CAC: Витрати / Реєстрації (вартість одного підписника)
  ROUND(SAFE_DIVIDE(SUM(daily_spend), SUM(daily_registrations)), 2) AS cac
FROM daily_metrics
GROUP BY 1
ORDER BY total_spend DESC
)

SELECT 
    mbc.*,
     ROUND(
      COALESCE(firstAOV, 0) + 
      (COALESCE(rebillAOV, 0) * COALESCE(rebills_per_payer_6m, 0)) + 
      (COALESCE(upsellAOV, 0) * COALESCE(cr_sub_upsell_raw, 0)), 
    2) AS ltv,
        round( ROUND(
      COALESCE(firstAOV, 0) + 
      (COALESCE(rebillAOV, 0) * COALESCE(rebills_per_payer_6m, 0)) + 
      (COALESCE(upsellAOV, 0) * COALESCE(cr_sub_upsell_raw, 0)), 
    2)/mbc.CAC,2) as dev_ltv_cac 
FROM metrics_calculation mc 
join metrics_by_channel mbc
on mc.channel=mbc.channel
ORDER BY mc.channel