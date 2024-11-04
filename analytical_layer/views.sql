USE credit;

DELIMITER //
CREATE EVENT IF NOT EXISTS refresh_member_balance_snapshot
ON SCHEDULE EVERY 1 DAY
STARTS '2024-11-03 03:00:00'
DO
BEGIN
	IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
               WHERE TABLE_SCHEMA = 'credit' AND TABLE_NAME = 'member_balance_snapshot') THEN
        TRUNCATE TABLE member_balance_snapshot;
    END IF;
    
    INSERT INTO member_balance_snapshot
	SELECT 
		m.member_no,
		m.lastname,
		m.firstname,
		m.curr_balance,
		COALESCE(SUM(c.charge_amt), 0) AS outstanding_charges,
		MAX(c.charge_dt) AS last_charge_dt,
		MAX(p.payment_dt) AS last_payment_dt,
		-- Current month charge count and amount
		COUNT(c.charge_no) AS current_month_charge_count,
		COALESCE(SUM(c.charge_amt), 0) AS current_month_charge_amt,
		-- Previous month charge count and amount
		COALESCE(prev.charge_count, 0) AS prev_month_charge_count,
		COALESCE(prev.charge_amt, 0) AS prev_month_charge_amt,
		-- Change in charge count and amount from previous month to current month
		COUNT(c.charge_no) - prev.charge_count AS charge_count_change,
		(SUM(c.charge_amt) - prev.charge_amt)/prev.charge_amt AS charge_amt_change
	FROM member m
	LEFT JOIN charge c ON m.member_no = c.member_no AND DATE_FORMAT(c.charge_dt, '%Y-%m') = DATE_FORMAT(NOW(), '%Y-%m') -- Filter for current month
	LEFT JOIN payment p ON m.member_no = p.member_no
	-- Subquery to calculate previous month’s charge count and amount
	LEFT JOIN (
		SELECT 
			member_no,
			COUNT(charge_no) AS charge_count,
			SUM(charge_amt) AS charge_amt
		FROM charge
		WHERE DATE_FORMAT(charge_dt, '%Y-%m') = DATE_FORMAT(DATE_SUB(NOW(), INTERVAL 1 MONTH), '%Y-%m')
		GROUP BY member_no
	) AS prev ON m.member_no = prev.member_no
	GROUP BY m.member_no;
END//


CREATE EVENT IF NOT EXISTS refresh_category_analysis
ON SCHEDULE EVERY 1 DAY
STARTS '2024-11-03 03:00:00'
DO
BEGIN
	IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
               WHERE TABLE_SCHEMA = 'credit' AND TABLE_NAME = 'category_analysis') THEN
        TRUNCATE TABLE category_analysis;
    END IF;
    
    INSERT INTO category_analysis
	SELECT 
		cat.category_no,
		cat.category_desc,
		COUNT(c.charge_no) AS charge_count,
		COALESCE(SUM(c.charge_amt), 0) AS total_charges,
		COALESCE(AVG(c.charge_amt), 0) AS avg_charge_amt
	FROM category cat
	LEFT JOIN charge c ON cat.category_no = c.category_no
	GROUP BY cat.category_no;
END//

CREATE EVENT IF NOT EXISTS refresh_region_summary
ON SCHEDULE EVERY 1 DAY
STARTS '2024-11-03 03:00:00'
DO
BEGIN
    IF EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
               WHERE TABLE_SCHEMA = 'credit' AND TABLE_NAME = 'region_summary') THEN
        TRUNCATE TABLE region_summary;
    END IF;
    
    INSERT INTO region_summary
    SELECT 
		r.region_no,
		r.region_name,
		COUNT(DISTINCT m.member_no) AS active_members,
		COALESCE(SUM(c.charge_amt), 0) AS total_charges,
		COALESCE(SUM(p.payment_amt), 0) AS total_payments
	FROM region r
	LEFT JOIN member m ON r.region_no = m.region_no
	LEFT JOIN charge c ON m.member_no = c.member_no
	LEFT JOIN payment p ON m.member_no = p.member_no
	GROUP BY r.region_no
	ORDER BY r.region_no;
END //

DELIMITER ;