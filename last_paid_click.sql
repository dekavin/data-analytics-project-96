WITH paid_sessions AS (
    -- только платные клики
    SELECT
        s.visitor_id,
        s.visit_date,
        s.source   AS utm_source,
        s.medium   AS utm_medium,
        s.campaign AS utm_campaign
    FROM sessions s
    WHERE LOWER(s.medium) IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),
-- Лиды: для каждого лида последний платный клик до создания лида
lead_attribution AS (
    SELECT
        ps.visitor_id,
        ps.visit_date,
        ps.utm_source,
        ps.utm_medium,
        ps.utm_campaign,
        l.lead_id,
        l.created_at,
        l.amount,
        l.closing_reason,
        l.status_id,
        ROW_NUMBER() OVER (
            PARTITION BY l.lead_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM leads l
    JOIN paid_sessions ps
        ON ps.visitor_id = l.visitor_id
       AND ps.visit_date <= l.created_at
),
-- Посетители без лидов: их последний платный клик
no_lead_attribution AS (
    SELECT
        ps.visitor_id,
        ps.visit_date,
        ps.utm_source,
        ps.utm_medium,
        ps.utm_campaign,
        NULL::text      AS lead_id,
        NULL::timestamp AS created_at,
        NULL::numeric   AS amount,
        NULL::text      AS closing_reason,
        NULL::integer   AS status_id,
        ROW_NUMBER() OVER (
            PARTITION BY ps.visitor_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM paid_sessions ps
    WHERE NOT EXISTS (
        SELECT 1 FROM leads l WHERE l.visitor_id = ps.visitor_id
    )
)
SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
       lead_id, created_at, amount, closing_reason, status_id
FROM lead_attribution
WHERE rn = 1
UNION ALL
SELECT visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
       lead_id, created_at, amount, closing_reason, status_id
FROM no_lead_attribution
WHERE rn = 1
ORDER BY
    amount DESC NULLS LAST,
    visit_date ASC,
    utm_source ASC,
    utm_medium ASC,
    utm_campaign ASC;