INSERT INTO theme_catalog (theme_id, display_name, price_points, valid_days, enabled)
VALUES ('qingluan-water', '青鸾照水', 60, 365, TRUE)
ON CONFLICT (theme_id) DO NOTHING;
