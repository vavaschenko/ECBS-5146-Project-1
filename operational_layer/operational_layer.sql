# Creating the schema for the project
CREATE SCHEMA IF NOT EXISTS credit;
USE credit;

# Data was added to the schema by running the SQL scripts attached in the raw_data folder of the repository
#ALTER TABLE member
#DROP COLUMN photograph;
delete from charge where charge_no > 100000; #this is to eschew memory issues

# Creating stored procedures 
DELIMITER //

DROP PROCEDURE IF EXISTS AddNewMember;
CREATE PROCEDURE AddNewMember (
    IN p_member_no INT,
    IN p_lastname VARCHAR(15),
    IN p_firstname VARCHAR(15),
    IN p_middleinitial CHAR(1),
    IN p_street VARCHAR(15),
    IN p_city VARCHAR(15),
    IN p_state_prov CHAR(2),
    IN p_country CHAR(2),
    IN p_mail_code CHAR(10),
    IN p_phone_no CHAR(13),
    IN p_corp_no INT,
    IN p_region_no INT,
    IN p_issue_dt DATETIME,
    IN p_expr_dt DATETIME,
    IN p_prev_balance INT,
    IN p_curr_balance INT,
    IN p_member_code CHAR(2)
)
BEGIN
    #Validates that the corporation and region exist
    IF NOT EXISTS (SELECT 1 FROM corporation WHERE corp_no = p_corp_no) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Corporation does not exist';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM region WHERE region_no = p_region_no) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Region does not exist';
    END IF;

    #Inserts the new member
    INSERT INTO member (member_no, lastname, firstname, middleinitial, street, city, state_prov, country, mail_code, phone_no, corp_no, region_no, issue_dt, expr_dt, member_code)
    VALUES (p_member_no, p_lastname, p_firstname, p_middleinitial, p_street, p_city, p_state_prov, p_country, p_mail_code, p_phone_no, p_corp_no, p_region_no, p_issue_dt, p_expr_dt, p_member_code);
END //

DROP PROCEDURE IF EXISTS ProcessPayment;
CREATE PROCEDURE ProcessPayment (
    IN p_payment_no INT,
    IN p_member_no INT,
    IN p_payment_amt DECIMAL(19, 4),
    IN p_payment_dt DATETIME,
    IN p_payment_code CHAR(2),
    IN p_statement_no INT
)
BEGIN
    #Inserts the payment record
    INSERT INTO payment (payment_no, member_no, payment_amt, payment_dt, payment_code, statement_no)
    VALUES (p_payment_no, p_member_no, p_payment_amt, p_payment_dt, p_payment_code, p_statement_no);

    #Updates the member's current balance
    UPDATE member
    SET curr_balance = curr_balance - p_payment_amt
    WHERE member_no = p_member_no;
END //

DROP PROCEDURE IF EXISTS GenerateMonthlyStatements;
CREATE PROCEDURE GenerateMonthlyStatements (IN p_statement_dt DATE)
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_member_no INT;
    DECLARE v_statement_amt DECIMAL(10, 2);

    #Declare a cursor to iterate through all members
    DECLARE member_cursor CURSOR FOR
        SELECT member_no
        FROM member;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    OPEN member_cursor;
    member_loop: LOOP
        FETCH member_cursor INTO v_member_no;
        IF done THEN
            LEAVE member_loop;
        END IF;

		#Calculates statement amount as the sum of unpaid charges
        SET v_statement_amt = (SELECT COALESCE(SUM(charge_amt), 0) FROM charge WHERE member_no = v_member_no AND statement_no IS NULL);

        #Inserts the statement record
        IF v_statement_amt > 0 THEN
            INSERT INTO statement (member_no, statement_dt, due_dt, statement_amt, statement_code)
            VALUES (v_member_no, p_statement_dt, DATE_ADD(p_statement_dt, INTERVAL 30 DAY), v_statement_amt, 'MTH');

            #Updates charges to link them to the newly created statement
            UPDATE charge
            SET statement_no = LAST_INSERT_ID()
            WHERE member_no = v_member_no AND statement_no IS NULL;
        END IF;
    END LOOP;

    CLOSE member_cursor;
END //

DROP PROCEDURE IF EXISTS ChargeMemberAccount;
CREATE PROCEDURE ChargeMemberAccount (
    IN p_charge_no INT,
    IN p_member_no INT,
    IN p_provider_no INT,
    IN p_category_no INT,
    IN p_charge_amt DECIMAL(10, 2),
    IN p_charge_dt DATETIME,
    IN p_charge_code CHAR(2),
    IN p_statement_no INT
)
BEGIN
    #Validate that the provider and category exist
    IF NOT EXISTS (SELECT 1 FROM provider WHERE provider_no = p_provider_no) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Provider does not exist';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM category WHERE category_no = p_category_no) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Category does not exist';
    END IF;

    #Insert the charge record
    INSERT INTO charge (charge_no, member_no, provider_no, category_no, charge_amt, charge_dt, charge_code, statement_no)
    VALUES (p_charge_no, p_member_no, p_provider_no, p_category_no, p_charge_amt, p_charge_dt, p_charge_code, p_statement_no);

    #Update the member's current balance
    UPDATE member
    SET curr_balance = curr_balance + p_charge_amt
    WHERE member_no = p_member_no;
END //

DROP PROCEDURE IF EXISTS UpdateMemberInformation;
CREATE PROCEDURE UpdateMemberInformation (
    IN p_member_no INT,
    IN p_street VARCHAR(255),
    IN p_city VARCHAR(100),
    IN p_state_prov CHAR(2),
    IN p_country CHAR(2),
    IN p_mail_code CHAR(10),
    IN p_phone_no CHAR(15)
)
BEGIN
    UPDATE credit.member
    SET street = p_street,
        city = p_city,
        state_prov = p_state_prov,
        country = p_country,
        mail_code = p_mail_code,
        phone_no = p_phone_no
    WHERE member_no = p_member_no;
END //

# Add trigger
-- DROP TRIGGER IF EXISTS check_data_on_insert;
-- CREATE TRIGGER before_member_delete
-- BEFORE DELETE ON member
-- FOR EACH ROW
-- BEGIN
--     DECLARE outstanding_charges INT;
--     DECLARE unpaid_statements INT;

--     #Check for outstanding charges
--     SELECT COUNT(*) INTO outstanding_charges
--     FROM charge
--     WHERE member_no = OLD.member_no AND statement_no IS NULL;

--     #Check for unpaid statements
--     SELECT COUNT(*) INTO unpaid_statements
--     FROM statement
--     WHERE member_no = OLD.member_no AND due_dt > NOW();

--     #Prevent deletion if there are outstanding charges or unpaid statements
--     IF outstanding_charges > 0 OR unpaid_statements > 0 THEN
--         SIGNAL SQLSTATE '45000'
--         SET MESSAGE_TEXT = 'Cannot delete member with outstanding charges or unpaid statements';
--     END IF;
-- END //

DROP PROCEDURE IF EXISTS DataConsistencyCheck;
CREATE PROCEDURE DataConsistencyCheck()
BEGIN
    DECLARE total_inconsistencies INT DEFAULT 0;

    #1. Check Member Balance Consistency
    DECLARE balance_inconsistencies INT;
	DECLARE orphaned_charges INT;
    DECLARE orphaned_payments INT;
    DECLARE orphaned_statements INT;
    
    SELECT COUNT(*) INTO balance_inconsistencies
    FROM member m
    LEFT JOIN (
        SELECT member_no, COALESCE(SUM(charge_amt), 0) AS total_charges
        FROM charge
        GROUP BY member_no
    ) AS c ON m.member_no = c.member_no
    LEFT JOIN (
        SELECT member_no, COALESCE(SUM(payment_amt), 0) AS total_payments
        FROM payment
        GROUP BY member_no
    ) AS p ON m.member_no = p.member_no
    WHERE m.curr_balance <> (COALESCE(c.total_charges, 0) - COALESCE(p.total_payments, 0));

    IF balance_inconsistencies > 0 THEN
        SET total_inconsistencies = total_inconsistencies + balance_inconsistencies;
        SELECT CONCAT('Balance inconsistency found for ', balance_inconsistencies, ' members.') AS Message;
    ELSE
        SELECT 'No balance inconsistencies found.' AS Message;
    END IF;

    #2. Check for Orphaned Records in Charge Table

    SELECT COUNT(*) INTO orphaned_charges
    FROM charge c
    LEFT JOIN member m ON c.member_no = m.member_no
    WHERE m.member_no IS NULL;

    IF orphaned_charges > 0 THEN
        SET total_inconsistencies = total_inconsistencies + orphaned_charges;
        SELECT CONCAT('Orphaned records found in charge table: ', orphaned_charges) AS Message;
    ELSE
        SELECT 'No orphaned records found in charge table.' AS Message;
    END IF;

    #3. Check for Orphaned Records in Payment Table

    SELECT COUNT(*) INTO orphaned_payments
    FROM payment p
    LEFT JOIN member m ON p.member_no = m.member_no
    WHERE m.member_no IS NULL;

    IF orphaned_payments > 0 THEN
        SET total_inconsistencies = total_inconsistencies + orphaned_payments;
        SELECT CONCAT('Orphaned records found in payment table: ', orphaned_payments) AS Message;
    ELSE
        SELECT 'No orphaned records found in payment table.' AS Message;
    END IF;

    #4. Check for Orphaned Records in Statement Table

    SELECT COUNT(*) INTO orphaned_statements
    FROM statement s
    LEFT JOIN member m ON s.member_no = m.member_no
    WHERE m.member_no IS NULL;

    IF orphaned_statements > 0 THEN
        SET total_inconsistencies = total_inconsistencies + orphaned_statements;
        SELECT CONCAT('Orphaned records found in statement table: ', orphaned_statements) AS Message;
    ELSE
        SELECT 'No orphaned records found in statement table.' AS Message;
    END IF;

    #Final Summary
    IF total_inconsistencies = 0 THEN
        SELECT 'Data consistency check completed successfully. No inconsistencies found.' AS Message;
    ELSE
        SELECT CONCAT('Data consistency check completed with ', total_inconsistencies, ' inconsistencies found.') AS Message;
    END IF;
END //

DELIMITER ;

# Now we can test these procedures and add some more relevant data to the database
# Let's create a user 

CALL AddNewMember(10001, 'Vashchenko', 'Vasilisa', 'A', 'Street', 'City', 'PR', 
					'RU', '0123456789', '+7 1234567889', 1, 1, '2024-11-02', '2024-11-02', 0, 0, '01');
    
# Now make a charge on this account
CALL ChargeMemberAccount(2000001, 10001, 28, 7, 2000.37, current_timestamp(), '01', 20001);

# Now let's make the payment to close the outstanding balance
CALL ProcessPayment(15555, 10001, 2000.37, current_timestamp(), '01', 20001);

CALL DataConsistencyCheck(); #9114 inconsistencies found because I am working with a wonderfully curated dataset :)
