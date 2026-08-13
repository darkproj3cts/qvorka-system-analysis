-- Qvorka: схема базы данных
-- PostgreSQL 15+
-- Деньги хранятся в копейках (integer) — избегаем проблем с округлением

-- =====================
-- Пользователи
-- =====================

CREATE TABLE users (
    id                 SERIAL PRIMARY KEY,
    email              VARCHAR(255) NOT NULL UNIQUE,
    password_hash      VARCHAR(255) NOT NULL,
    role               VARCHAR(20)  NOT NULL CHECK (role IN ('client', 'freelancer', 'admin')),
    full_name          VARCHAR(255) NOT NULL,
    avatar_url         VARCHAR(500),
    bio                TEXT,
    is_email_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    is_verified        BOOLEAN NOT NULL DEFAULT FALSE,
    is_blocked         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at         TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMP
);

-- Расширенный профиль только для исполнителей
CREATE TABLE freelancer_profiles (
    id                     SERIAL PRIMARY KEY,
    user_id                INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    specialization         VARCHAR(255),
    rating                 NUMERIC(3, 2) NOT NULL DEFAULT 0.00 CHECK (rating >= 0 AND rating <= 5),
    completed_orders_count INTEGER NOT NULL DEFAULT 0,
    portfolio_url          VARCHAR(500),
    updated_at             TIMESTAMP
);

-- =====================
-- Каталог
-- =====================

-- parent_id = NULL означает корневую категорию (дизайн, разработка и т.д.)
CREATE TABLE categories (
    id        SERIAL PRIMARY KEY,
    name      VARCHAR(100) NOT NULL,
    slug      VARCHAR(100) NOT NULL UNIQUE,
    parent_id INTEGER REFERENCES categories(id) ON DELETE SET NULL
);

CREATE TABLE services (
    id               SERIAL PRIMARY KEY,
    freelancer_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id      INTEGER NOT NULL REFERENCES categories(id),
    title            VARCHAR(255) NOT NULL,
    description      TEXT,
    -- новые услуги проходят модерацию перед публикацией (FR-44)
    status           VARCHAR(20) NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft', 'pending', 'published', 'rejected')),
    rejection_reason TEXT,
    created_at       TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMP
);

-- У одной услуги от 1 до 3 пакетов (FR-12)
CREATE TABLE service_packages (
    id              SERIAL PRIMARY KEY,
    service_id      INTEGER NOT NULL REFERENCES services(id) ON DELETE CASCADE,
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    price           INTEGER NOT NULL CHECK (price > 0),
    delivery_days   INTEGER NOT NULL CHECK (delivery_days > 0),
    revisions_count INTEGER NOT NULL DEFAULT 1 CHECK (revisions_count >= 0)
);

CREATE TABLE service_tags (
    id         SERIAL PRIMARY KEY,
    service_id INTEGER NOT NULL REFERENCES services(id) ON DELETE CASCADE,
    tag        VARCHAR(50) NOT NULL
);

CREATE TABLE service_images (
    id         SERIAL PRIMARY KEY,
    service_id INTEGER NOT NULL REFERENCES services(id) ON DELETE CASCADE,
    url        VARCHAR(500) NOT NULL,
    position   INTEGER NOT NULL DEFAULT 0
);

-- =====================
-- Заказы
-- =====================

CREATE TABLE orders (
    id                SERIAL PRIMARY KEY,
    service_id        INTEGER NOT NULL REFERENCES services(id),
    package_id        INTEGER NOT NULL REFERENCES service_packages(id),
    client_id         INTEGER NOT NULL REFERENCES users(id),
    freelancer_id     INTEGER NOT NULL REFERENCES users(id),
    status            VARCHAR(20) NOT NULL DEFAULT 'in_progress'
                          CHECK (status IN ('in_progress', 'in_review', 'completed', 'cancelled', 'dispute')),
    requirements      TEXT,
    total_price       INTEGER NOT NULL CHECK (total_price > 0),
    commission_amount INTEGER NOT NULL CHECK (commission_amount >= 0),
    revisions_used    INTEGER NOT NULL DEFAULT 0,
    deadline_at       TIMESTAMP,
    completed_at      TIMESTAMP,
    created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMP
);

-- История смены статусов заказа (нужна для споров и аналитики)
CREATE TABLE order_status_history (
    id         SERIAL PRIMARY KEY,
    order_id   INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status     VARCHAR(20) NOT NULL,
    changed_by INTEGER NOT NULL REFERENCES users(id),
    comment    TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =====================
-- Чат
-- =====================

CREATE TABLE messages (
    id         SERIAL PRIMARY KEY,
    order_id   INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    sender_id  INTEGER NOT NULL REFERENCES users(id),
    content    TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE message_attachments (
    id         SERIAL PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    file_url   VARCHAR(500) NOT NULL,
    file_name  VARCHAR(255),
    file_size  INTEGER CHECK (file_size > 0)
);

-- =====================
-- Отзывы и споры
-- =====================

-- Один пользователь может оставить один отзыв на один заказ (FR-30)
-- Срок — 14 дней после завершения (FR-31), контролируется на уровне приложения
CREATE TABLE reviews (
    id          SERIAL PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(id),
    reviewer_id INTEGER NOT NULL REFERENCES users(id),
    reviewee_id INTEGER NOT NULL REFERENCES users(id),
    rating      SMALLINT NOT NULL CHECK (rating >= 1 AND rating <= 5),
    comment     TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (order_id, reviewer_id)
);

-- Спор открывается только при статусе in_progress или in_review (FR-35)
CREATE TABLE disputes (
    id           SERIAL PRIMARY KEY,
    order_id     INTEGER NOT NULL REFERENCES orders(id),
    initiator_id INTEGER NOT NULL REFERENCES users(id),
    moderator_id INTEGER REFERENCES users(id),
    reason       TEXT NOT NULL,
    status       VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
    resolution   TEXT,
    created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
    resolved_at  TIMESTAMP
);

-- =====================
-- Финансы
-- =====================

CREATE TABLE wallets (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    balance    INTEGER NOT NULL DEFAULT 0 CHECK (balance >= 0),
    updated_at TIMESTAMP
);

CREATE TABLE transactions (
    id         SERIAL PRIMARY KEY,
    wallet_id  INTEGER NOT NULL REFERENCES wallets(id),
    order_id   INTEGER REFERENCES orders(id),
    type       VARCHAR(20) NOT NULL
                   CHECK (type IN ('payment', 'earning', 'withdrawal', 'refund')),
    amount     INTEGER NOT NULL CHECK (amount > 0),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Минимальная сумма вывода — 500 рублей = 50000 копеек (FR-42)
CREATE TABLE withdrawals (
    id           SERIAL PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id),
    amount       INTEGER NOT NULL CHECK (amount >= 50000),
    card_last4   VARCHAR(4),
    status       VARCHAR(20) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'completed', 'rejected')),
    created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMP
);

-- =====================
-- Уведомления
-- =====================

CREATE TABLE notifications (
    id               SERIAL PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type             VARCHAR(50) NOT NULL
                         CHECK (type IN (
                             'new_order', 'work_submitted', 'revision_requested',
                             'order_completed', 'dispute_opened', 'dispute_resolved'
                         )),
    title            VARCHAR(255) NOT NULL,
    body             TEXT,
    is_read          BOOLEAN NOT NULL DEFAULT FALSE,
    related_order_id INTEGER REFERENCES orders(id) ON DELETE SET NULL,
    created_at       TIMESTAMP NOT NULL DEFAULT NOW()
);

-- =====================
-- Индексы
-- =====================

CREATE INDEX idx_services_freelancer ON services(freelancer_id);
CREATE INDEX idx_services_category   ON services(category_id);
CREATE INDEX idx_services_status     ON services(status);
CREATE INDEX idx_orders_client       ON orders(client_id);
CREATE INDEX idx_orders_freelancer   ON orders(freelancer_id);
CREATE INDEX idx_orders_status       ON orders(status);
CREATE INDEX idx_messages_order      ON messages(order_id);
CREATE INDEX idx_reviews_reviewee    ON reviews(reviewee_id);
CREATE INDEX idx_notifications_user  ON notifications(user_id, is_read);
CREATE INDEX idx_disputes_status     ON disputes(status);
