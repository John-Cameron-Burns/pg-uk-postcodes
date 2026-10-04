EXTENSION    = postcode
EXTVERSION   = 2.0.0

MODULE_big   = postcode
OBJS         = postcode.o binfmt.o postal_code.o postal_code_fmt.o postal_code_country.o \
                postal_code_us.o postal_code_ca.o postal_code_fr.o postal_code_br.o postal_code_cz.o postal_code_lu.o \
                postal_code_gb.o postal_code_ie.o postal_code_pattern.o postal_code_lang.o
DATA         = postcode--1.3.0.sql postcode--1.3.1.sql postcode--1.3.2.sql postcode--1.3.3.sql postcode--1.3.4.sql postcode--1.3.5.sql postcode--2.0.0.sql \
                postcode--1.3.0--1.3.1.sql postcode--1.3.1--1.3.2.sql postcode--1.3.2--1.3.3.sql postcode--1.3.3--1.3.4.sql postcode--1.3.4--1.3.5.sql postcode--1.3.5--2.0.0.sql
REGRESS      = parser binary sort random quirks format match partial dps range cast support selectivity postal_code
REGRESS_OPTS = --load-extension=$(EXTENSION)
PG_CPPFLAGS  = -std=c99 -Wall -DEXTVERSION=$(EXTVERSION) -DTRUE=true -DFALSE=false

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

override CFLAGS := $(filter-out -Wdeclaration-after-statement, $(CFLAGS))

# PGXS doesn't track header dependencies: without this, a header-only change
# (e.g. a new pc_format enum value changing PC_FMT_MAX) leaves stale .o files
# that still have the old value compiled in -- which bit this build once.
$(OBJS): postal_code.h postal_code_fmt.h postal_code_country.h postal_code_pattern.h postal_code_lang.h postcode.h binfmt.h areas.h dps.h

# "binary" (COPY ... WITH BINARY, exercising postcode's/dps's binary send/recv functions -- a
# completely separate code path from the text-based tests that make up the rest of this suite)
# reads a data file from a fixed path, so sql/binary.sql.in is turned into sql/binary.sql with
# its @abs_srcdir@ token substituted, and the data file is staged there. PGXS (unlike the full
# PostgreSQL source tree's regress makefile) does not do that substitution for out-of-tree
# extensions. It is ALWAYS regenerated (a phony target, not a file rule) and sql/binary.sql is not
# tracked or shipped: a stale copy from another checkout would be newer than its source, skip the
# staging step, and fail the test. The template is deliberately NOT under input/: PostgreSQL 14's
# pg_regress converts input/*.source itself, with the build directory as @abs_srcdir@, overwriting this.
#
# The staging path is FIXED, not $(CURDIR), so expected/binary.out (which contains the substituted
# path, since pg_regress diffs the echoed query text too) is one portable checked-in file.
BINARY_TEST_DIR = /tmp/postcode_binary_test

.PHONY: binary-test-fixture
binary-test-fixture:
	mkdir -p $(BINARY_TEST_DIR)/data
	cp data/binary.data $(BINARY_TEST_DIR)/data/binary.data
	sed 's,@abs_srcdir@,$(BINARY_TEST_DIR),g' sql/binary.sql.in > sql/binary.sql

installcheck: binary-test-fixture
check: binary-test-fixture

EXTRA_CLEAN = sql/binary.sql

# postcode--$(EXTVERSION).sql is generated from the upgrade script (see tools/build_install_script.sh).
.PHONY: install-script verify-install-script
install-script:
	sh tools/build_install_script.sh > postcode--$(EXTVERSION).sql

verify-install-script:
	sh tools/build_install_script.sh | diff -u postcode--$(EXTVERSION).sql - \
	   && echo "postcode--$(EXTVERSION).sql is up to date with postcode--1.3.5--$(EXTVERSION).sql"
