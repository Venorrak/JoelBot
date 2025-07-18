USE joelScan;

SELECT
    joels.count as totalJoels,
    users.creationDate as firstJoelDate
FROM users
JOIN joels ON users.id = joels.user_id
WHERE users.name = 'venorrak'
LIMIT 1;

SELECT
    channels.name as MostJoelsInStreamStreamer,
    streamUsersJoels.count as mostJoelsInStream,
    streamJoels.streamDate as mostJoelsInStreamDate
FROM users
JOIN streamUsersJoels ON users.id = streamUsersJoels.user_id
JOIN streamJoels ON streamUsersJoels.stream_id = streamJoels.id
JOIN channels ON streamJoels.channel_id = channels.id
WHERE users.name = 'venorrak' AND streamUsersJoels.count = (SELECT MAX(streamUsersJoels.count) FROM streamUsersJoels WHERE user_id = users.id);

SELECT
    channels.name as mostJoeledStreamer,
    (SELECT SUM(streamUsersJoels.count) WHERE streamUsersJoels.user_id = users.id AND streamUsersJoels.stream_id = streamJoels.id ) as count
FROM users
JOIN streamUsersJoels ON users.id = streamUsersJoels.user_id
JOIN streamJoels ON streamUsersJoels.stream_id = streamJoels.id
JOIN channels ON streamJoels.channel_id = channels.id
WHERE users.name = 'venorrak'
GROUP BY channels.id
ORDER BY count DESC;