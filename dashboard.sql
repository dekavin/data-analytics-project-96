-- 1. Витрина Last Paid Click 

CREATE OR REPLACE TEMP VIEW last_paid_click AS
WITH paid_sessions AS (
    SELECT s.visitor_id, s.visit_date, s.source AS utm_source, s.medium AS utm_medium, s.campaign AS utm_campaign
    FROM sessions s
    WHERE LOWER(s.medium) IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),
lead_attribution AS (
    SELECT ps.visitor_id, ps.visit_date, ps.utm_source, ps.utm_medium, ps.utm_campaign,
           l.lead_id, l.created_at, l.amount, l.closing_reason, l.status_id,
           ROW_NUMBER() OVER (PARTITION BY l.lead_id ORDER BY ps.visit_date DESC) AS rn
    FROM leads l
    JOIN paid_sessions ps ON ps.visitor_id = l.visitor_id AND ps.visit_date <= l.created_at
),
no_lead_attribution AS (
    SELECT ps.visitor_id, ps.visit_date, ps.utm_source, ps.utm_medium, ps.utm_campaign,
           NULL::text AS lead_id, NULL::timestamp AS created_at, NULL::numeric AS amount,
           NULL::text AS closing_reason, NULL::integer AS status_id,
           ROW_NUMBER() OVER (PARTITION BY ps.visitor_id ORDER BY ps.visit_date DESC) AS rn
    FROM paid_sessions ps
    WHERE NOT EXISTS (SELECT 1 FROM leads l WHERE l.visitor_id = ps.visitor_id)
)
SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign, lead_id, created_at, amount, closing_reason, status_id
FROM lead_attribution WHERE rn = 1
UNION ALL
SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign, lead_id, created_at, amount, closing_reason, status_id
FROM no_lead_attribution WHERE rn = 1;

-- 2. Дневная агрегированная витрина с расходами 

CREATE OR REPLACE TEMP VIEW agg_daily AS
WITH visits_agg AS (
    SELECT visit_date::date AS visit_date, utm_source, utm_medium, utm_campaign,
           COUNT(DISTINCT visitor_id) AS visitors_count,
           COUNT(lead_id) AS leads_count,
           COUNT(*) FILTER (WHERE closing_reason = 'Успешно реализовано' OR status_id = 142) AS purchases_count,
           SUM(amount) FILTER (WHERE closing_reason = 'Успешно реализовано' OR status_id = 142) AS revenue
    FROM last_paid_click
    GROUP BY 1, 2, 3, 4
),
ads AS (
    SELECT campaign_date::date AS visit_date, utm_source, utm_medium, utm_campaign, SUM(daily_spent) AS total_cost
    FROM (
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM vk_ads
        UNION ALL
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM ya_ads
    ) a
    GROUP BY 1, 2, 3, 4
)
SELECT v.visit_date, v.visitors_count, v.utm_source, v.utm_medium, v.utm_campaign,
       a.total_cost, v.leads_count, v.purchases_count, v.revenue
FROM visits_agg v
LEFT JOIN ads a ON a.visit_date = v.visit_date AND a.utm_source = v.utm_source
               AND a.utm_medium = v.utm_medium AND a.utm_campaign = v.utm_campaign;

-- 3. Метрики по utm_source (cpu, cpl, cppu, roi)

SELECT utm_source,
       SUM(visitors_count) AS visitors_count,
       SUM(leads_count) AS leads_count,
       SUM(purchases_count) AS purchases_count,
       SUM(total_cost) AS total_cost,
       SUM(revenue) AS revenue,
       ROUND(SUM(total_cost) / NULLIF(SUM(visitors_count), 0), 2) AS cpu,
       ROUND(SUM(total_cost) / NULLIF(SUM(leads_count), 0), 2) AS cpl,
       ROUND(SUM(total_cost) / NULLIF(SUM(purchases_count), 0), 2) AS cppu,
       ROUND((SUM(revenue) - SUM(total_cost)) / NULLIF(SUM(total_cost), 0) * 100, 2) AS roi
FROM agg_daily
GROUP BY utm_source
ORDER BY roi DESC NULLS LAST;

-- 4. Те же метрики в разрезе source / medium / campaign

SELECT utm_source, utm_medium, utm_campaign,
       SUM(visitors_count) AS visitors_count,
       SUM(leads_count) AS leads_count,
       SUM(purchases_count) AS purchases_count,
       SUM(total_cost) AS total_cost,
       SUM(revenue) AS revenue,
       ROUND(SUM(total_cost) / NULLIF(SUM(visitors_count), 0), 2) AS cpu,
       ROUND(SUM(total_cost) / NULLIF(SUM(leads_count), 0), 2) AS cpl,
       ROUND(SUM(total_cost) / NULLIF(SUM(purchases_count), 0), 2) AS cppu,
       ROUND((SUM(revenue) - SUM(total_cost)) / NULLIF(SUM(total_cost), 0) * 100, 2) AS roi
FROM agg_daily
GROUP BY utm_source, utm_medium, utm_campaign
ORDER BY revenue DESC NULLS LAST, visitors_count DESC, utm_source, utm_medium, utm_campaign;

-- 5. Динамика по дням 

SELECT DATE_TRUNC('day', visit_date)::date AS period, utm_source,
       SUM(visitors_count) AS visitors_count,
       SUM(leads_count) AS leads_count,
       SUM(purchases_count) AS purchases_count,
       SUM(total_cost) AS total_cost,
       SUM(revenue) AS revenue
FROM agg_daily
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6. Воронка и конверсии по каналам: клик → лид, лид → оплата

SELECT utm_source,
       SUM(visitors_count) AS visitors_count,
       SUM(leads_count) AS leads_count,
       SUM(purchases_count) AS purchases_count,
       ROUND(SUM(leads_count)::numeric / NULLIF(SUM(visitors_count), 0) * 100, 2) AS conv_click_to_lead_pct,
       ROUND(SUM(purchases_count)::numeric / NULLIF(SUM(leads_count), 0) * 100, 2) AS conv_lead_to_purchase_pct
FROM agg_daily
GROUP BY utm_source
ORDER BY conv_click_to_lead_pct DESC NULLS LAST;

-- 7. За сколько дней от клика по рекламе появляется 90% лидов

SELECT COUNT(*) AS leads_total,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (created_at - visit_date)) / 86400)::numeric, 1) AS days_for_90pct_leads
FROM last_paid_click
WHERE lead_id IS NOT NULL;
-- То же по каналам
SELECT utm_source, COUNT(*) AS leads_total,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (created_at - visit_date)) / 86400)::numeric, 1) AS days_for_90pct_leads
FROM last_paid_click
WHERE lead_id IS NOT NULL
GROUP BY utm_source
ORDER BY days_for_90pct_leads;

-- 8. Данные для графика: расходы на рекламу и органика по дням

WITH organic AS (
    SELECT visit_date::date AS d, COUNT(DISTINCT visitor_id) AS organic_visits
    FROM sessions
    WHERE LOWER(medium) = 'organic'
    GROUP BY 1
),
spend AS (
    SELECT d, SUM(daily_spent) AS cost
    FROM (
        SELECT campaign_date::date AS d, daily_spent FROM vk_ads
        UNION ALL
        SELECT campaign_date::date AS d, daily_spent FROM ya_ads
    ) x
    GROUP BY 1
)
SELECT o.d, o.organic_visits, COALESCE(s.cost, 0) AS cost
FROM organic o
LEFT JOIN spend s ON s.d = o.d
ORDER BY o.d;

WITH organic AS (
    SELECT visit_date::date AS d, COUNT(DISTINCT visitor_id) AS organic_visits
    FROM sessions
    WHERE LOWER(medium) = 'organic'
    GROUP BY 1
),
spend AS (
    SELECT d, SUM(daily_spent) AS cost
    FROM (
        SELECT campaign_date::date AS d, daily_spent FROM vk_ads
        UNION ALL
        SELECT campaign_date::date AS d, daily_spent FROM ya_ads
    ) x
    GROUP BY 1
),
daily AS (
    SELECT o.d, o.organic_visits, COALESCE(s.cost, 0) AS cost,
           LAG(COALESCE(s.cost, 0)) OVER (ORDER BY o.d) AS cost_prev_day
    FROM organic o
    LEFT JOIN spend s ON s.d = o.d
)
SELECT ROUND(CORR(organic_visits, cost)::numeric, 3) AS corr_same_day,
       ROUND(CORR(organic_visits, cost_prev_day)::numeric, 3) AS corr_lag_1_day
FROM daily;

-- 9. Решение по каналам: оставить / доработать / отключить

WITH by_campaign AS (
    SELECT utm_source, utm_medium, utm_campaign,
           SUM(total_cost) AS total_cost,
           SUM(revenue) AS revenue,
           ROUND((SUM(revenue) - SUM(total_cost)) / NULLIF(SUM(total_cost), 0) * 100, 1) AS roi
    FROM agg_daily
    GROUP BY 1, 2, 3
)
SELECT utm_source, utm_medium, utm_campaign, total_cost, revenue, roi,
       CASE
           WHEN roi >= 50 THEN 'Не трогать'
           WHEN roi >= 0 THEN 'Улучшать'
           ELSE 'Отключить или пересмотреть'
       END AS decision
FROM by_campaign
WHERE total_cost > 0
ORDER BY roi DESC NULLS LAST;
-- Кампании, которые потратили бюджет без единой оплаты
SELECT utm_source, utm_medium, utm_campaign,
       SUM(total_cost) AS total_cost,
       SUM(leads_count) AS leads_count,
       SUM(purchases_count) AS purchases_count
FROM agg_daily
GROUP BY 1, 2, 3
HAVING SUM(purchases_count) = 0 AND SUM(total_cost) > 0
ORDER BY total_cost DESC;