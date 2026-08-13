-- Qvorka: аналитические запросы
-- PostgreSQL 15+

-- =====================
-- 1. Топ фрилансеров по выручке
-- Считаем чистую выручку (сумма заказов минус комиссия платформы)
-- только по завершённым заказам
-- =====================

SELECT
    u.full_name,
    fp.specialization,
    fp.rating,
    fp.completed_orders_count,
    COUNT(o.id)                              AS orders_in_db,
    SUM(o.total_price - o.commission_amount) AS net_revenue,
    ROUND(AVG(o.total_price) / 100.0, 2)    AS avg_order_rub
FROM users u
JOIN freelancer_profiles fp ON fp.user_id = u.id
LEFT JOIN orders o ON o.freelancer_id = u.id AND o.status = 'completed'
GROUP BY u.id, u.full_name, fp.specialization, fp.rating, fp.completed_orders_count
ORDER BY net_revenue DESC NULLS LAST;


-- =====================
-- 2. Распределение заказов по статусам
-- Даёт картину текущей загрузки платформы
-- =====================

SELECT
    status,
    COUNT(*)                                        AS cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM orders
GROUP BY status
ORDER BY cnt DESC;


-- =====================
-- 3. Средний чек по категориям
-- Смотрим на какие категории приходится основной оборот
-- =====================

SELECT
    c_parent.name   AS category,
    c_child.name    AS subcategory,
    COUNT(o.id)     AS order_count,
    ROUND(AVG(o.total_price) / 100.0, 2) AS avg_check_rub,
    SUM(o.total_price) / 100             AS total_revenue_rub
FROM orders o
JOIN services s        ON s.id = o.service_id
JOIN categories c_child  ON c_child.id = s.category_id
LEFT JOIN categories c_parent ON c_parent.id = c_child.parent_id
GROUP BY c_parent.name, c_child.name
ORDER BY total_revenue_rub DESC;


-- =====================
-- 4. Конверсия: сколько заказов завершилось без проблем
-- =====================

SELECT
    COUNT(*)                                                        AS total_orders,
    COUNT(*) FILTER (WHERE status = 'completed')                   AS completed,
    COUNT(*) FILTER (WHERE status = 'dispute')                     AS in_dispute,
    COUNT(*) FILTER (WHERE status = 'cancelled')                   AS cancelled,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'completed') * 100.0 / COUNT(*), 1
    )                                                               AS completion_rate_pct
FROM orders;


-- =====================
-- 5. Window functions: ранжирование фрилансеров внутри категории
-- RANK() - чтобы показать позицию каждого в своей нише
-- =====================

SELECT
    u.full_name,
    c.name                                            AS subcategory,
    fp.rating,
    fp.completed_orders_count,
    RANK() OVER (
        PARTITION BY s.category_id
        ORDER BY fp.rating DESC, fp.completed_orders_count DESC
    )                                                 AS rank_in_category
FROM services s
JOIN users u                ON u.id = s.freelancer_id
JOIN freelancer_profiles fp ON fp.user_id = u.id
JOIN categories c           ON c.id = s.category_id
WHERE s.status = 'published'
ORDER BY c.name, rank_in_category;


-- =====================
-- 6. Window functions: нарастающая выручка по заказам (SUM OVER)
-- Показывает как накапливался оборот платформы
-- =====================

SELECT
    o.id                                    AS order_id,
    u.full_name                             AS client,
    s.title                                 AS service,
    o.total_price / 100                     AS price_rub,
    o.created_at::date                      AS order_date,
    SUM(o.total_price) OVER (
        ORDER BY o.created_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / 100                                 AS cumulative_revenue_rub
FROM orders o
JOIN users u    ON u.id = o.client_id
JOIN services s ON s.id = o.service_id
ORDER BY o.created_at;


-- =====================
-- 7. Window functions: LAG() - сравнение правок между заказами
-- Смотрим сколько правок использовал каждый фрилансер в динамике
-- =====================

SELECT
    u.full_name              AS freelancer,
    o.id                     AS order_id,
    o.created_at::date       AS order_date,
    o.revisions_used,
    LAG(o.revisions_used) OVER (
        PARTITION BY o.freelancer_id
        ORDER BY o.created_at
    )                        AS prev_order_revisions,
    o.revisions_used - LAG(o.revisions_used) OVER (
        PARTITION BY o.freelancer_id
        ORDER BY o.created_at
    )                        AS delta
FROM orders o
JOIN users u ON u.id = o.freelancer_id
ORDER BY o.freelancer_id, o.created_at;


-- =====================
-- 8. ROW_NUMBER(): нумерация заказов каждого клиента по времени
-- Помогает найти первый заказ (онбординг) и отследить retention
-- =====================

SELECT
    u.full_name         AS client,
    o.id                AS order_id,
    o.created_at::date  AS order_date,
    s.title             AS service,
    o.status,
    ROW_NUMBER() OVER (
        PARTITION BY o.client_id
        ORDER BY o.created_at
    )                   AS order_num
FROM orders o
JOIN users u    ON u.id = o.client_id
JOIN services s ON s.id = o.service_id
ORDER BY u.full_name, order_num;


-- =====================
-- 9. Активность в чате по заказам
-- Больше сообщений - сложнее задача или больше правок
-- =====================

SELECT
    o.id                    AS order_id,
    s.title                 AS service,
    uc.full_name            AS client,
    uf.full_name            AS freelancer,
    o.status,
    COUNT(m.id)             AS message_count,
    o.revisions_used
FROM orders o
JOIN services s  ON s.id = o.service_id
JOIN users uc    ON uc.id = o.client_id
JOIN users uf    ON uf.id = o.freelancer_id
LEFT JOIN messages m ON m.order_id = o.id
GROUP BY o.id, s.title, uc.full_name, uf.full_name, o.status, o.revisions_used
ORDER BY message_count DESC;


-- =====================
-- 10. Финансовый баланс платформы
-- Сколько заработала платформа на комиссиях с завершённых заказов
-- =====================

SELECT
    SUM(commission_amount) / 100           AS platform_earned_rub,
    SUM(total_price - commission_amount) / 100 AS freelancers_earned_rub,
    SUM(total_price) / 100                 AS gross_volume_rub
FROM orders
WHERE status = 'completed';


-- =====================
-- VIEW 1: Сводка по фрилансерам для дашборда
-- =====================

CREATE OR REPLACE VIEW v_freelancer_summary AS
SELECT
    u.id,
    u.full_name,
    u.is_verified,
    fp.specialization,
    fp.rating,
    fp.completed_orders_count,
    COUNT(s.id)                                         AS active_services,
    COALESCE(SUM(o.total_price - o.commission_amount) FILTER (
        WHERE o.status = 'completed'
    ), 0) / 100                                         AS net_revenue_rub,
    w.balance / 100                                     AS wallet_balance_rub
FROM users u
JOIN freelancer_profiles fp ON fp.user_id = u.id
LEFT JOIN services s        ON s.freelancer_id = u.id AND s.status = 'published'
LEFT JOIN orders o          ON o.freelancer_id = u.id
LEFT JOIN wallets w         ON w.user_id = u.id
GROUP BY u.id, u.full_name, u.is_verified, fp.specialization,
         fp.rating, fp.completed_orders_count, w.balance;


-- =====================
-- VIEW 2: Открытые споры с деталями для модератора
-- =====================

CREATE OR REPLACE VIEW v_open_disputes AS
SELECT
    d.id                    AS dispute_id,
    d.created_at::date      AS opened_at,
    o.id                    AS order_id,
    s.title                 AS service,
    uc.full_name            AS client,
    uf.full_name            AS freelancer,
    o.total_price / 100     AS order_amount_rub,
    d.reason,
    d.status
FROM disputes d
JOIN orders o   ON o.id = d.order_id
JOIN services s ON s.id = o.service_id
JOIN users uc   ON uc.id = o.client_id
JOIN users uf   ON uf.id = o.freelancer_id
WHERE d.status = 'open'
ORDER BY d.created_at;
