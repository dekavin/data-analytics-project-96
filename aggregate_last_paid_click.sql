WITH tab AS (
    SELECT
        s.visitor_id,
        s.visit_date,
        s.source AS utm_source,
        s.medium AS utm_medium,
        s.campaign AS utm_campaign,
        l.lead_id,
        l.amount,
        l.closing_reason,
        l.status_id,
        ROW_NUMBER() OVER (
            PARTITION BY s.visitor_id
            ORDER BY s.visit_date DESC, l.created_at ASC
        ) AS rn
    FROM sessions AS s
    LEFT JOIN leads AS l
        ON s.visitor_id = l.visitor_id AND s.visit_date <= l.created_at
    WHERE LOWER(s.medium) IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

ads AS (
    SELECT
        campaign_date::date AS visit_date,
        utm_source,
        utm_medium,
        utm_campaign,
        SUM(daily_spent) AS total_cost
    FROM (
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM vk_ads
        UNION ALL
        SELECT campaign_date, utm_source, utm_medium, utm_campaign, daily_spent FROM ya_ads
    ) AS a
    GROUP BY 1, 2, 3, 4
)

SELECT
    t.visit_date::date AS visit_date,
    COUNT(DISTINCT t.visitor_id) AS visitors_count,
    t.utm_source,
    t.utm_medium,
    t.utm_campaign,
    a.total_cost,
    COUNT(t.lead_id) AS leads_count,
    COUNT(*) FILTER (WHERE t.closing_reason = 'Успешно реализовано' OR t.status_id = 142) AS purchases_count,
    SUM(t.amount) FILTER (WHERE t.closing_reason = 'Успешно реализовано' OR t.status_id = 142) AS revenue
FROM tab AS t
LEFT JOIN ads AS a
    ON
        t.visit_date::date = a.visit_date
        AND t.utm_source = a.utm_source
        AND t.utm_medium = a.utm_medium
        AND t.utm_campaign = a.utm_campaign
WHERE t.rn = 1
GROUP BY t.visit_date::date, t.utm_source, t.utm_medium, t.utm_campaign, a.total_cost
ORDER BY
    revenue DESC NULLS LAST,
    visit_date ASC,
    visitors_count DESC,
    utm_source ASC,
    utm_medium ASC,
    utm_campaign ASC
LIMIT 15;