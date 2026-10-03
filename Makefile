EXTENSION    = postcode
EXTVERSION   = 2.0.0

MODULE_big   = postcode
OBJS         = postcode.o binfmt.o postal_code.o postal_code_fmt.o postal_code_country.o \
                postal_code_us.o postal_code_ca.o postal_code_fr.o postal_code_br.o postal_code_cz.o postal_code_lu.o \
                postal_code_gb.o postal_code_ie.o postal_code_template.o postal_code_tpl.o
DATA         = postcode--1.3.0.sql postcode--1.3.1.sql postcode--1.3.2.sql postcode--1.3.3.sql postcode--1.3.4.sql postcode--1.3.5.sql postcode--2.0.0.sql \
                postcode--1.3.0--1.3.1.sql postcode--1.3.1--1.3.2.sql postcode--1.3.2--1.3.3.sql postcode--1.3.3--1.3.4.sql postcode--1.3.4--1.3.5.sql postcode--1.3.5--2.0.0.sql
REGRESS      = parser binary sort random quirks format match partial dps range cast support selectivity postal_code
REGRESS_OPTS = --load-extension=$(EXTENSION)
PG_CPPFLAGS  = -std=c99 -Wall -Wpedantic -DEXTVERSION=$(EXTVERSION) -DTRUE=true -DFALSE=false

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

override CFLAGS := $(filter-out -Wdeclaration-after-statement, $(CFLAGS))

# PGXS doesn't track header dependencies: without this, a header-only change
# (e.g. a new pc_format enum value changing PC_FMT_MAX) leaves stale .o files
# that still have the old value compiled in -- which bit this build once.
$(OBJS): postal_code.h postal_code_fmt.h postal_code_country.h postal_code_template.h postal_code_tpl.h postcode.h binfmt.h areas.h dps.h

# "binary" (COPY ... WITH BINARY, exercising postcode's/dps's binary
# send/recv functions -- a completely separate code path from the
# text-based tests that make up the rest of this suite) was never
# actually wired up to run: input/binary.source needs its @abs_srcdir@
# token substituted into a real sql/binary.sql before pg_regress can use
# it, and PGXS (unlike the full Postgres source tree's own regress
# GNUmakefile) doesn't supply that substitution rule automatically for
# out-of-tree extensions -- confirmed missing even in the pristine
# upstream 1.3.1 source, so this was never a working test, not something
# broken by the 1.3.2 fix. Added 2026-08-31.
#
# Substitutes a FIXED staging path, not $(CURDIR)/the real build
# directory -- so expected/binary.out (which necessarily contains the
# substituted path verbatim, since pg_regress diffs the echoed query
# text too) can be one portable, checked-in file that matches on any
# machine, not something that has to be regenerated per build location.
# (The previous expected/binary.out had the ORIGINAL upstream author's
# own literal dev path baked in -- /home/dave/dev/postcode/... -- which
# is exactly this same problem, unsolved.)
BINARY_TEST_DIR = /tmp/postcode_binary_test

sql/binary.sql: input/binary.source
	mkdir -p $(BINARY_TEST_DIR)/data
	cp data/binary.data $(BINARY_TEST_DIR)/data/binary.data
	sed 's,@abs_srcdir@,$(BINARY_TEST_DIR),g' $< > $@

installcheck: sql/binary.sql
check: sql/binary.sql

EXTRA_CLEAN = sql/binary.sql
