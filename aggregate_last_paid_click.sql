WITH last_paid_click AS (
    SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign, lead_id, created_at, amount, closing_reason, status_id
    FROM (
        SELECT s.visitor_id, s.visit_date, s.source AS utm_source, s.medium AS utm_medium, s.campaign AS utm_campaign,
               l.lead_id, l.created_at, l.amount, l.closing_reason, l.status_id,
               ROW_NUMBER() OVER (PARTITION BY s.visitor_id ORDER BY s.visit_date DESC, l.created_at ASC) AS rn
        FROM sessions s
        LEFT JOIN leads l ON l.visitor_id = s.visitor_id AND l.created_at >= s.visit_date
        WHERE LOWER(s.medium) IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
    ) t
    WHERE rn = 1
),
visits_agg AS (
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
SELECT v.visit_date, v.utm_source, v.utm_medium, v.utm_campaign,
       v.visitors_count, v.leads_count, v.purchases_count,
       COALESCE(a.total_cost, 0) AS total_cost,
       COALESCE(v.revenue, 0) AS revenue
FROM visits_agg v
LEFT JOIN ads a ON a.visit_date = v.visit_date AND a.utm_source = v.utm_source
              AND a.utm_medium = v.utm_medium AND a.utm_campaign = v.utm_campaign
