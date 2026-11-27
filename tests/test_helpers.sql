-- test_helpers.sql
-- Shared by the SQL test files; included with \ir after their BEGIN, so the
-- helper lives in the session's temporary schema and disappears on ROLLBACK.
-- Not a test itself: scripts/run_tests.sh only runs files named *_test.sql.
--
-- Test fixtures follow two rules: names start with an upper-case label saying
-- which test made them, and any email address uses the reserved .invalid
-- domain, so a fixture can never reach a real customer.

-- pg_temp.check(name, condition): print "ok" or stop the test with "FAIL".
-- A function, not a procedure: CALL arguments may not contain subqueries.
CREATE FUNCTION pg_temp.check(test_name text, condition boolean)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF condition IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL  %', test_name;
    END IF;
    RAISE NOTICE 'ok    %', test_name;
END
$$;
