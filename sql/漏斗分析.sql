-- ============================================================
-- 电商用户行为分析：MySQL 流量 / 漏斗 / RFM 交叉验证
-- 数据：data/userbehavior_1m.csv（01 生成，100 万条原始样本）
-- 实际字段（6 列）：user_id,item_id,behavior_type,user_geohash,item_category,time
--   behavior_type：1=pv 浏览  2=buy 购买  3=fav 收藏  4=cart 加购（数字编码！）
--   time：'yyyy-MM-dd HH'（精确到小时）
-- 运行方式（命令行，需开启 local_infile）：
--   SET GLOBAL local_infile = 1;
--   mysql -uroot -p --local-infile=1 < sql/漏斗分析.sql
-- ============================================================

CREATE DATABASE IF NOT EXISTS taobao DEFAULT CHARSET utf8mb4;
USE taobao;

DROP TABLE IF EXISTS user_behavior_raw;
CREATE TABLE user_behavior_raw (
  user_id       VARCHAR(20),
  item_id       VARCHAR(20),
  behavior_type TINYINT,          -- 1 pv / 2 buy / 3 fav / 4 cart
  user_geohash  VARCHAR(20),
  item_category VARCHAR(20),
  `time`        DATETIME
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 注意：文件是 6 列，最后一列 time 需从 'yyyy-MM-dd HH' 转成 DATETIME
-- 坑：MySQL on Windows 读不了含中文的路径（errno 2），失败时把 CSV 复制到纯英文目录再改这里
LOAD DATA LOCAL INFILE 'E:/数据分析/Mine/电商/data/userbehavior_1m.csv'
INTO TABLE user_behavior_raw
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(user_id, item_id, behavior_type, user_geohash, item_category, @t)
SET `time` = STR_TO_DATE(@t, '%Y-%m-%d %H');

-- 与 01 notebook 对齐：丢掉 geohash（缺失 68%，无分析价值），再按其余 5 列去重
-- 1,000,000 条 → 939,270 条
-- 注意：若把 user_geohash 也放进 DISTINCT，只差 geohash 的行会留下来，结果变成 959,181 条，与 Python 对不上
DROP TABLE IF EXISTS user_behavior;
CREATE TABLE user_behavior AS
SELECT DISTINCT user_id, item_id, behavior_type, item_category, `time`
FROM user_behavior_raw;
DROP TABLE user_behavior_raw;

-- ------------------------------------------------------------------
-- 0. 数据体检：总行数 / 用户数 / 时间范围（应与 01、02 一致：939,270 条、9,929 人）
-- ------------------------------------------------------------------
SELECT COUNT(*) AS 总行数, COUNT(DISTINCT user_id) AS 用户数,
       MIN(`time`) AS 起始时间, MAX(`time`) AS 结束时间
FROM user_behavior;

-- 1. 流量总览：PV / UV / 人均浏览
SELECT
  COUNT(*)                                                       AS 总行为数,
  SUM(behavior_type = 1)                                         AS PV,
  COUNT(DISTINCT user_id)                                        AS UV,
  ROUND(SUM(behavior_type = 1) / COUNT(DISTINCT user_id), 1)     AS 人均浏览量
FROM user_behavior;

-- 2. 用户口径转化漏斗：浏览 → 兴趣(收藏∪加购) → 购买
SELECT
  COUNT(DISTINCT CASE WHEN behavior_type = 1 THEN user_id END)        AS 浏览用户,
  COUNT(DISTINCT CASE WHEN behavior_type IN (3, 4) THEN user_id END)  AS 兴趣用户,
  COUNT(DISTINCT CASE WHEN behavior_type = 2 THEN user_id END)        AS 购买用户
FROM user_behavior;

-- 3. 加购 → 购买 转化（高意向用户的流失）
SELECT
  COUNT(*)                                              AS 加购用户,
  SUM(b.user_id IS NOT NULL)                            AS 加购且购买,
  ROUND(SUM(b.user_id IS NOT NULL) / COUNT(*) * 100, 1) AS 转化率百分比
FROM (SELECT DISTINCT user_id FROM user_behavior WHERE behavior_type = 4) c
LEFT JOIN (SELECT DISTINCT user_id FROM user_behavior WHERE behavior_type = 2) b
       ON c.user_id = b.user_id;

-- 3.1 收藏 → 购买 转化（对照组）
SELECT
  COUNT(*)                                              AS 收藏用户,
  SUM(b.user_id IS NOT NULL)                            AS 收藏且购买,
  ROUND(SUM(b.user_id IS NOT NULL) / COUNT(*) * 100, 1) AS 转化率百分比
FROM (SELECT DISTINCT user_id FROM user_behavior WHERE behavior_type = 3) c
LEFT JOIN (SELECT DISTINCT user_id FROM user_behavior WHERE behavior_type = 2) b
       ON c.user_id = b.user_id;

-- 4. 每日 PV / UV 趋势（含双 12 对比）
SELECT
  DATE(`time`)                                                  AS 日期,
  SUM(behavior_type = 1)                                        AS PV,
  COUNT(DISTINCT user_id)                                       AS UV,
  COUNT(DISTINCT CASE WHEN behavior_type = 2 THEN user_id END)  AS 购买UV
FROM user_behavior
GROUP BY DATE(`time`)
ORDER BY 日期;

-- 5. 双 12 当天 vs 日常均值
SELECT
  MAX(CASE WHEN 日期 = '2014-12-12' THEN PV END)                       AS 双12_PV,
  ROUND(AVG(CASE WHEN 日期 <> '2014-12-12' THEN PV END), 0)            AS 日常_PV均值,
  ROUND(MAX(CASE WHEN 日期 = '2014-12-12' THEN PV END) /
        AVG(CASE WHEN 日期 <> '2014-12-12' THEN PV END), 2)            AS 倍数
FROM (SELECT DATE(`time`) AS 日期, SUM(behavior_type = 1) AS PV
      FROM user_behavior GROUP BY DATE(`time`)) t;

-- 6. 小时活跃分布
SELECT HOUR(`time`) AS 小时, SUM(behavior_type = 1) AS PV,
       COUNT(DISTINCT user_id) AS UV
FROM user_behavior
GROUP BY HOUR(`time`)
ORDER BY 小时;

-- ------------------------------------------------------------------
-- 7. RFM（R/F 两维，无金额字段，M 用购买频次近似）
-- ------------------------------------------------------------------
CREATE OR REPLACE VIEW v_rfm AS
SELECT
  user_id,
  DATEDIFF('2014-12-19', MAX(DATE(`time`)))  AS R,   -- 距基准日天数
  COUNT(*)                                  AS F    -- 购买次数
FROM user_behavior
WHERE behavior_type = 2
GROUP BY user_id;

-- 7.1 固定阈值分层（R ≤ 7 天、F ≥ 5 次）——与 notebook 03 的敏感性检验同口径
--     预期：价值 27.4% / 发展 23.1% / 保持 7.7% / 挽留 41.8%
--     注：notebook 主结果用的是分位数打分（R、F 各切 1-5 分再以中位数划分），
--         SQL 里用 NTILE 不能完全复现 qcut 的分箱边界，所以这里只做阈值版校验
SELECT
  CASE
    WHEN R <= 7 AND F >= 5 THEN '重要价值客户'
    WHEN R <= 7 AND F <  5 THEN '重要发展客户'
    WHEN R >  7 AND F >= 5 THEN '重要保持客户'
    ELSE '重要挽留客户'
  END                                                       AS 用户分层,
  COUNT(*)                                                  AS 用户数,
  ROUND(COUNT(*) / (SELECT COUNT(*) FROM v_rfm) * 100, 1)    AS 占比百分比,
  ROUND(AVG(R), 1)                                          AS 平均R,
  ROUND(AVG(F), 1)                                          AS 平均F
FROM v_rfm
GROUP BY 用户分层
ORDER BY 用户数 DESC;

-- 7.2 对照：更宽松的阈值（R ≤ 7 天、F ≥ 3 次）
SELECT
  CASE
    WHEN R <= 7 AND F >= 3 THEN '重要价值客户'
    WHEN R <= 7 AND F <  3 THEN '重要发展客户'
    WHEN R >  7 AND F >= 3 THEN '重要保持客户'
    ELSE '重要挽留客户'
  END                       AS 用户分层_宽松阈值,
  COUNT(*)                  AS 用户数,
  ROUND(COUNT(*) / (SELECT COUNT(*) FROM v_rfm) * 100, 1) AS 占比百分比
FROM v_rfm
GROUP BY 用户分层_宽松阈值
ORDER BY 用户数 DESC;
