WITH paid_sessions AS (
    SELECT
        s.visitor_id,
        s.visit_date,
        s.source   AS utm_source,
        s.medium   AS utm_medium,
        s.campaign AS utm_campaign
    FROM sessions s
    WHERE LOWER(s.medium) IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),
lead_attribution AS (
    SELECT
        ps.visitor_id, ps.visit_date, ps.utm_source, ps.utm_medium, ps.utm_campaign,
        l.lead_id, l.created_at, l.amount, l.closing_reason, l.status_id,
        ROW_NUMBER() OVER (PARTITION BY l.lead_id ORDER BY ps.visit_date DESC) AS rn
    FROM leads l
    JOIN paid_sessions ps
        ON ps.visitor_id = l.visitor_id
       AND ps.visit_date <= l.created_at
),
no_lead_attribution AS (
    SELECT
        ps.visitor_id, ps.visit_date, ps.utm_source, ps.utm_medium, ps.utm_campaign,
        NULL::text      AS lead_id,
        NULL::timestamp AS created_at,
        NULL::numeric   AS amount,
        NULL::text      AS closing_reason,
        NULL::integer   AS status_id,
        ROW_NUMBER() OVER (PARTITION BY ps.visitor_id ORDER BY ps.visit_date DESC) AS rn
    FROM paid_sessions ps
    WHERE NOT EXISTS (SELECT 1 FROM leads l WHERE l.visitor_id = ps.visitor_id)
),
last_paid_click AS (
    SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
           lead_id, created_at, amount, closing_reason, status_id
    FROM lead_attribution WHERE rn = 1
    UNION ALL
    SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
           lead_id, created_at, amount, closing_reason, status_id
    FROM no_lead_attribution WHERE rn = 1
),
visits_agg AS (
    SELECT
        visit_date::date AS visit_date,
        utm_source,
        utm_medium,
        utm_campaign,
        COUNT(DISTINCT visitor_id) AS visitors_count,
        COUNT(lead_id) AS leads_count,
        COUNT(*) FILTER (WHERE closing_reason = 'Успешно реализовано' OR status_id = 142) AS purchases_count,
        SUM(amount) FILTER (WHERE closing_reason = 'Успешно реализовано' OR status_id = 142) AS revenue
    FROM last_paid_click
    GROUP BY 1, 2, 3, 4
),
ads AS (
    SELECT campaign_date::date AS visit_date, utm_source, utm_medium, utm_campaign,
           SUM(daily_spent) AS total_cost
    FROM (
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM vk_ads
        UNION ALL
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM ya_ads
    ) a
    GROUP BY 1, 2, 3, 4
)
SELECT
    v.visit_date,
    v.visitors_count,
    v.utm_source,
    v.utm_medium,
    v.utm_campaign,
    a.total_cost,
    v.leads_count,
    v.purchases_count,
    v.revenue
FROM visits_agg v
LEFT JOIN ads a
    ON a.visit_date = v.visit_date
   AND a.utm_source = v.utm_source
   AND a.utm_medium = v.utm_medium
   AND a.utm_campaign = v.utm_campaign
ORDER BY
    v.revenue DESC NULLS LAST,
    v.visit_date ASC,
    v.visitors_count DESC,
    v.utm_source ASC,
    v.utm_medium ASC,
    v.utm_campaign ASC;