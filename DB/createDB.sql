DROP DATABASE IF EXISTS joelScanTest;
CREATE DATABASE joelScanTest;

CREATE USER IF NOT EXISTS 'bot'@'localhost' IDENTIFIED BY 'joel';
GRANT ALL ON *.* TO 'bot'@'localhost';

USE joelScanTest;

CREATE TABLE IF NOT EXISTS pictures(
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    url VARCHAR(200) NOT NULL,
    type VARCHAR(30) NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    twitch_id INT NOT NULL,
    pfp_id INT NOT NULL,
    bgp_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    creationDate DATE NOT NULL,
    FOREIGN KEY (pfp_id) REFERENCES pictures(id),
    FOREIGN KEY (bgp_id) REFERENCES pictures(id)
);

CREATE TABLE IF NOT EXISTS channels (
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    creationDate DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS joels (
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    user_id INT NOT NULL,
    count DOUBLE NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS channelJoels (
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    channel_id INT NOT NULL,
    count DOUBLE NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id)
);

CREATE TABLE IF NOT EXISTS streamJoels (
    id INT AUTO_INCREMENT NOT NULL PRIMARY KEY,
    channel_id INT NOT NULL,
    count INT NOT NULL,
    streamDate DATE NOT NULL,
    FOREIGN KEY (channel_id) REFERENCES channels(id)
);
