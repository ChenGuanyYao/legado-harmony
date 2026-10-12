INSERT INTO theme_catalog (theme_id, display_name, price_points, valid_days, enabled)
VALUES ('azure-mecha', '苍穹机动', 90, 365, TRUE),
       ('starwish-magic', '星愿魔法', 90, 365, TRUE)
ON CONFLICT (theme_id) DO NOTHING;
