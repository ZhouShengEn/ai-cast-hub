-- AI Cast Hub MySQL 初始化脚本
CREATE DATABASE IF NOT EXISTS ai_cast_hub
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE ai_cast_hub;

-- 设备表
CREATE TABLE IF NOT EXISTS devices (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_uuid VARCHAR(64) NOT NULL UNIQUE,
    device_name VARCHAR(128) NOT NULL,
    platform VARCHAR(32) NOT NULL DEFAULT 'unknown',
    transfer_key VARCHAR(128) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_device_uuid (device_uuid),
    INDEX idx_last_seen (last_seen_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 设备绑定关系表
CREATE TABLE IF NOT EXISTS device_bindings (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_a VARCHAR(64) NOT NULL,
    device_b VARCHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_binding (device_a, device_b),
    INDEX idx_device_a (device_a),
    INDEX idx_device_b (device_b),
    FOREIGN KEY (device_a) REFERENCES devices(device_uuid) ON DELETE CASCADE,
    FOREIGN KEY (device_b) REFERENCES devices(device_uuid) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 对话表
CREATE TABLE IF NOT EXISTS conversations (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    model_name VARCHAR(64) NOT NULL,
    title VARCHAR(256) NOT NULL DEFAULT '新对话',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_device_id (device_id),
    FOREIGN KEY (device_id) REFERENCES devices(device_uuid) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 消息表
CREATE TABLE IF NOT EXISTS messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    conversation_id INT NOT NULL,
    role ENUM('user', 'assistant', 'system') NOT NULL,
    content TEXT NOT NULL,
    model_name VARCHAR(64),
    input_tokens INT DEFAULT 0,
    output_tokens INT DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_conversation (conversation_id),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- API Key 表（加密存储）
CREATE TABLE IF NOT EXISTS api_keys (
    id INT AUTO_INCREMENT PRIMARY KEY,
    provider VARCHAR(32) NOT NULL UNIQUE,
    encrypted_key TEXT NOT NULL,
    key_label VARCHAR(128) DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Token 用量统计表
CREATE TABLE IF NOT EXISTS token_usage (
    id INT AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    model_name VARCHAR(64) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    input_tokens INT NOT NULL DEFAULT 0,
    output_tokens INT NOT NULL DEFAULT 0,
    total_tokens INT AS (input_tokens + output_tokens) STORED,
    cost DECIMAL(10, 6) DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_device_id (device_id),
    INDEX idx_model (model_name),
    INDEX idx_created (created_at),
    FOREIGN KEY (device_id) REFERENCES devices(device_uuid) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 文件传输记录表
CREATE TABLE IF NOT EXISTS file_transfers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    transfer_id VARCHAR(64) NOT NULL UNIQUE,
    from_device VARCHAR(64) NOT NULL,
    to_device VARCHAR(64) NOT NULL,
    file_name VARCHAR(256) NOT NULL,
    file_size BIGINT NOT NULL,
    checksum VARCHAR(128),
    status ENUM('pending', 'transferring', 'completed', 'failed', 'cancelled') NOT NULL DEFAULT 'pending',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_from_device (from_device),
    INDEX idx_to_device (to_device),
    FOREIGN KEY (from_device) REFERENCES devices(device_uuid) ON DELETE CASCADE,
    FOREIGN KEY (to_device) REFERENCES devices(device_uuid) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
