-- 2.0.0 -> 2.0.1: is_valid(text) and is_valid(text, text) become one function, is_valid_postal_code(text, cc DEFAULT NULL).
--
-- A bare is_valid() is too generic a name for an extension to own: 2.0.0's is_valid(text) collided with
-- the gsscode extension's is_valid(text) in the production IDM database (ALTER EXTENSION postcode UPDATE failed
-- with "function is_valid already exists with same argument types"), and wherever the isn extension is installed
-- (is_valid(isbn), is_valid(ean13), ...) an untyped literal such as is_valid('US-90210') was ambiguous anyway.
--
-- Callers of is_valid(...) must change to is_valid_postal_code(...); the arguments and results are the same, and
-- the second argument is now optional.
DROP FUNCTION is_valid(text);
DROP FUNCTION is_valid(text, text);

CREATE FUNCTION is_valid_postal_code(postcode text, cc text DEFAULT NULL)
   RETURNS boolean
   LANGUAGE sql STABLE
   AS 'SELECT CASE WHEN $1 IS NULL THEN NULL ELSE to_postal_code($1, $2) IS NOT NULL END';
