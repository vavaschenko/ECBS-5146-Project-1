USE credit;

SET GLOBAL event_scheduler = ON;

delete from charge where charge_no > 100000;

#Adding a denormalized structure
DELIMITER //
DROP PROCEDURE IF EXISTS UpdateDenormalizedPaymentInfo;
CREATE PROCEDURE UpdateDenormalizedPaymentInfo()
BEGIN
    #Create the table if it doesn't exist
    DROP TABLE IF EXISTS denormalized_payment_info;
    CREATE TABLE IF NOT EXISTS denormalized_payment_info (
        member_no INT,
        lastname VARCHAR(15),
        firstname VARCHAR(15),
        middleinitial CHAR(1),
        street VARCHAR(15),
        city VARCHAR(15),
        state_prov CHAR(2),
        country CHAR(2),
        mail_code CHAR(10),
        phone_no CHAR(13),
        corp_no INT,
        region_no INT,
        issue_dt DATETIME,
        expr_dt DATETIME,
        prev_balance INT,
        curr_balance INT,
        member_code CHAR(2),
        statement_no INT,
        statement_dt DATETIME,
        due_dt DATETIME,
        statement_amt DECIMAL(19, 4),
        statement_code CHAR(2),
        operation_type ENUM('payment', 'charge'),
        region_code CHAR(2), 
        region_name VARCHAR(15),
        corp_name VARCHAR(31),
        corp_code CHAR(2),
        charge_no INT,
        charge_dt DATETIME,
        charge_amt DECIMAL(19, 4),
        charge_code VARCHAR(2),
        category_no INT,
        category_desc VARCHAR(31),
        category_code VARCHAR(2),
        payment_no INT,
        payment_dt DATETIME,
        payment_amt DECIMAL(19, 4),
        payment_code VARCHAR(2),
        provider_no INT,
        provider_name VARCHAR(15),
        provider_code VARCHAR(2)
    );

    #Truncate the table to clear existing data
    TRUNCATE TABLE denormalized_payment_info;

    #Insert data into denormalized_payment_info table
    INSERT INTO denormalized_payment_info(member_no,lastname,firstname,middleinitial,street,city,
		state_prov, country,mail_code,phone_no,corp_no,region_no,issue_dt,expr_dt,prev_balance,
        curr_balance,member_code,statement_no,statement_dt,due_dt,statement_amt,statement_code,
        operation_type,region_code, region_name,corp_name,corp_code,charge_no,charge_dt,
        charge_amt,charge_code,category_no,category_desc,category_code,payment_no, 
        payment_dt, payment_amt, payment_code,provider_no,provider_name,provider_code
    )
    SELECT 
        m.member_no,
        m.lastname,
        m.firstname,
        m.middleinitial,
        m.street,
        m.city,
        m.state_prov,
        m.country,
        m.mail_code,
        m.phone_no,
        m.corp_no,
        m.region_no,
        m.issue_dt,
        m.expr_dt,
        m.prev_balance,
        m.curr_balance,
        m.member_code,
        st.statement_no,
        st.statement_dt,
        st.due_dt,
        st.statement_amt,
        st.statement_code,
        CASE WHEN p.payment_no IS NOT NULL THEN 'payment' ELSE 'charge' END AS operation_type,
        r.region_code, 
        r.region_name,
        c.corp_name,
        c.corp_code,
        ch.charge_no,
        ch.charge_dt,
        ch.charge_amt,
        ch.charge_code,
        cat.category_no,
        cat.category_desc,
        cat.category_code,
        p.payment_no, 
        p.payment_dt, 
        p.payment_amt, 
        p.payment_code,
        pr.provider_no,
        pr.provider_name,
        pr.provider_code
    FROM 
        member m
    LEFT JOIN 
        region r ON m.region_no = r.region_no
    LEFT JOIN 
        corporation c ON m.corp_no = c.corp_no
    LEFT JOIN 
        charge ch ON m.member_no = ch.member_no
    LEFT JOIN 
        payment p ON m.member_no = p.member_no
    LEFT JOIN 
        provider pr ON ch.provider_no = pr.provider_no
    LEFT JOIN 
        category cat ON ch.category_no = cat.category_no
    LEFT JOIN 
        statement st ON st.member_no = m.member_no;
END //

DROP EVENT hourly_update_denormalized_payment_info;
CREATE EVENT IF NOT EXISTS hourly_update_denormalized_payment_info
ON SCHEDULE EVERY 1 DAY
DO
BEGIN
    CALL UpdateDenormalizedPaymentInfo(); #this is a heavy weight operation so 
END //
DELIMITER ;

CREATE OR REPLACE VIEW member_balance AS 
SELECT c.member_no, 
		COALESCE(SUM(c.charge_amt), 0) AS current_outstanding_charges,
		MAX(c.charge_dt) AS last_charge_dt,
		MAX(c.payment_dt) AS last_payment_dt,
		#Current month charge count and amount
		COUNT(c.charge_no) AS current_month_charge_count,
		COALESCE(SUM(c.charge_amt), 0) AS current_month_charge_amt,
		#Previous month charge count and amount
		COALESCE(MAX(prev.charge_count), 0) AS prev_month_charge_count,
		COALESCE(MAX(prev.charge_amt), 0) AS prev_month_charge_amt,
		#Change in charge count and amount from previous month to current month
		COUNT(c.charge_no) - MAX(prev.charge_count) AS charge_count_change,
		(SUM(c.charge_amt) - MAX(prev.charge_amt))/MAX(prev.charge_amt) AS charge_amt_change
FROM (SELECT * FROM denormalized_payment_info
		WHERE DATE_FORMAT(charge_dt, '%Y-%m') = DATE_FORMAT(NOW(), '%Y-%m')) AS c
LEFT JOIN (
		SELECT 
			member_no,
			COUNT(charge_no) AS charge_count,
			SUM(charge_amt) AS charge_amt
		FROM denormalized_payment_info
		WHERE DATE_FORMAT(charge_dt, '%Y-%m') = DATE_FORMAT(DATE_SUB(NOW(), INTERVAL 1 MONTH), '%Y-%m')
		GROUP BY member_no
	) AS prev ON c.member_no = prev.member_no
GROUP BY member_no;

CREATE OR REPLACE VIEW member_balance_snapshot AS
SELECT 
		m.member_no,
		m.lastname,
		m.firstname,
		m.curr_balance,
		COALESCE(SUM(c.charge_amt), 0) AS outstanding_charges,
		MAX(c.charge_dt) AS last_charge_dt,
		MAX(p.payment_dt) AS last_payment_dt,
		#Current month charge count and amount
		COUNT(c.charge_no) AS current_month_charge_count,
		COALESCE(SUM(c.charge_amt), 0) AS current_month_charge_amt,
		#Previous month charge count and amount
		COALESCE(prev.charge_count, 0) AS prev_month_charge_count,
		COALESCE(prev.charge_amt, 0) AS prev_month_charge_amt,
		#Change in charge count and amount from previous month to current month
		COUNT(c.charge_no) - prev.charge_count AS charge_count_change,
		(SUM(c.charge_amt) - prev.charge_amt)/prev.charge_amt AS charge_amt_change
	FROM member m
	LEFT JOIN charge c ON m.member_no = c.member_no AND DATE_FORMAT(c.charge_dt, '%Y-%m') = DATE_FORMAT(NOW(), '%Y-%m') # Filter for current month
	LEFT JOIN payment p ON m.member_no = p.member_no
	#Subquery to calculate previous month’s charge count and amount
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

CREATE OR REPLACE VIEW category_analysis AS
SELECT 
		cat.category_no,
		cat.category_desc,
		COUNT(c.charge_no) AS charge_count,
		COALESCE(SUM(c.charge_amt), 0) AS total_charges,
		COALESCE(AVG(c.charge_amt), 0) AS avg_charge_amt
	FROM category cat
	LEFT JOIN charge c ON cat.category_no = c.category_no
	GROUP BY cat.category_no;

CREATE OR REPLACE VIEW region_summary AS
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