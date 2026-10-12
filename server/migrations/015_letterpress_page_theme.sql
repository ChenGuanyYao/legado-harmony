INSERT INTO theme_catalog (theme_id, display_name, price_points, valid_days, enabled)
VALUES ('letterpress-page', '铅字书页', 90, 365, TRUE)
ON CONFLICT (theme_id) DO NOTHING;
