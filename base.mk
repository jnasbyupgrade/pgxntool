PGXNTOOL_DIR := pgxntool

#
# META.json
#
PGXNTOOL_distclean += META.json
META.json: META.in.json $(PGXNTOOL_DIR)/build_meta.sh
	@$(PGXNTOOL_DIR)/build_meta.sh $< $@

#
# meta.mk
#
# Buind meta.mk, which contains info from META.json, and include it
PGXNTOOL_distclean += meta.mk
meta.mk: META.json Makefile $(PGXNTOOL_DIR)/base.mk $(PGXNTOOL_DIR)/meta.mk.sh
	@$(PGXNTOOL_DIR)/meta.mk.sh $< >$@

-include meta.mk

DATA         = $(EXTENSION_VERSION_FILES) $(wildcard sql/*--*--*.sql)
DOC_DIRS	+= doc
# NOTE: if this is empty it gets forcibly defined to NUL before including PGXS
DOCS		+= $(foreach dir,$(DOC_DIRS),$(wildcard $(dir)/*))

# Find all asciidoc targets
ASCIIDOC ?= $(shell which asciidoctor 2>/dev/null || which asciidoc 2>/dev/null)
ASCIIDOC_EXTS	+= adoc asciidoc
ASCIIDOC_FILES	+= $(foreach dir,$(DOC_DIRS),$(foreach ext,$(ASCIIDOC_EXTS),$(wildcard $(dir)/*.$(ext))))

PG_CONFIG   ?= pg_config
TESTDIR		?= test
TESTOUT		?= $(TESTDIR)
TEST_SOURCE_FILES	+= $(wildcard $(TESTDIR)/input/*.source)
TEST_OUT_SOURCE_FILES	+= $(wildcard $(TESTDIR)/output/*.source)
TEST_OUT_FILES		 = $(subst input,output,$(TEST_SOURCE_FILES))
TEST_SQL_FILES		+= $(wildcard $(TESTDIR)/sql/*.sql)
TEST_RESULT_FILES	 = $(patsubst $(TESTDIR)/sql/%.sql,$(TESTDIR)/expected/%.out,$(TEST_SQL_FILES))
TEST_FILES	 = $(TEST_SOURCE_FILES) $(TEST_SQL_FILES)
# Ephemeral files generated from source files (should be cleaned)
# input/*.source → sql/*.sql (converted by pg_regress)
TEST_SQL_FROM_SOURCE	 = $(patsubst $(TESTDIR)/input/%.source,$(TESTDIR)/sql/%.sql,$(TEST_SOURCE_FILES))
# output/*.source → expected/*.out (converted by pg_regress)
TEST_EXPECTED_FROM_SOURCE = $(patsubst $(TESTDIR)/output/%.source,$(TESTDIR)/expected/%.out,$(TEST_OUT_SOURCE_FILES))
REGRESS		 = $(sort $(notdir $(subst .source,,$(TEST_FILES:.sql=)))) # Sort is to get unique list
REGRESS_OPTS = --inputdir=$(TESTDIR) --outputdir=$(TESTOUT) # See additional setup below

#
# OPTIONAL TEST FEATURES
#
# These sections configure optional test features. Each feature can be enabled/disabled
# via a makefile variable. If not explicitly set, features auto-detect based on
# directory existence or default behavior. The actual feature implementation is
# located later in this file (see test-build target, schedule file generation, etc.).
#

# ------------------------------------------------------------------------------
# test-build: Sanity check extension files before running full test suite
# ------------------------------------------------------------------------------
# Purpose: Validates that extension SQL files are syntactically correct by running
#          files from test/build/ through pg_regress. This provides better error
#          messages than CREATE EXTENSION failures.
#
# Variable: PGXNTOOL_ENABLE_TEST_BUILD
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - If not set: Auto-detects based on existence of test/build/*.sql files
#   - Usage: Controls whether test-build target exists and runs before make test
#
# Implementation: See test-build target definition (search for "test-build:" in this file)
#
TEST_BUILD_FILES = $(wildcard $(TESTDIR)/build/*.sql) $(wildcard $(TESTDIR)/build/sql/*.sql)
ifdef PGXNTOOL_ENABLE_TEST_BUILD
  # User explicitly set the variable - validate and use their value
  PGXNTOOL_ENABLE_TEST_BUILD_NORM = $(strip $(shell echo "$(PGXNTOOL_ENABLE_TEST_BUILD)" | tr '[:upper:]' '[:lower:]'))
  ifneq ($(PGXNTOOL_ENABLE_TEST_BUILD_NORM),yes)
    ifneq ($(PGXNTOOL_ENABLE_TEST_BUILD_NORM),no)
      $(error PGXNTOOL_ENABLE_TEST_BUILD must be "yes" or "no", got "$(PGXNTOOL_ENABLE_TEST_BUILD)")
    endif
  endif
  # Use normalized value
  PGXNTOOL_ENABLE_TEST_BUILD = $(PGXNTOOL_ENABLE_TEST_BUILD_NORM)
else
  # Auto-detect: enable if test/build/ directory has SQL files
  ifneq ($(strip $(TEST_BUILD_FILES)),)
    PGXNTOOL_ENABLE_TEST_BUILD = yes
  else
    PGXNTOOL_ENABLE_TEST_BUILD = no
  endif
endif

# ------------------------------------------------------------------------------
# test/install: Performance optimization - run setup once before all tests
# ------------------------------------------------------------------------------
# Purpose: Runs files from test/install/ before all test/sql/ files, allowing
#          expensive setup (like extension installation) to happen once per test
#          run instead of in each test file's transaction.
#
# Variable: PGXNTOOL_ENABLE_TEST_INSTALL
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - If not set: Auto-detects based on existence of test/install/*.sql or *.source files
#   - Usage: Controls whether schedule file is generated to run test/install/ files first
#
# Implementation: See schedule file generation (search for "TEST_SCHEDULE_FILE" in this file)
#
TEST_INSTALL_FILES = $(wildcard $(TESTDIR)/install/*.sql) $(wildcard $(TESTDIR)/install/*.source)
ifdef PGXNTOOL_ENABLE_TEST_INSTALL
  # User explicitly set the variable - validate and use their value
  PGXNTOOL_ENABLE_TEST_INSTALL_NORM = $(strip $(shell echo "$(PGXNTOOL_ENABLE_TEST_INSTALL)" | tr '[:upper:]' '[:lower:]'))
  ifneq ($(PGXNTOOL_ENABLE_TEST_INSTALL_NORM),yes)
    ifneq ($(PGXNTOOL_ENABLE_TEST_INSTALL_NORM),no)
      $(error PGXNTOOL_ENABLE_TEST_INSTALL must be "yes" or "no", got "$(PGXNTOOL_ENABLE_TEST_INSTALL)")
    endif
  endif
  # Use normalized value
  PGXNTOOL_ENABLE_TEST_INSTALL = $(PGXNTOOL_ENABLE_TEST_INSTALL_NORM)
else
  # Auto-detect: enable if test/install/ directory has files
  ifneq ($(strip $(TEST_INSTALL_FILES)),)
    PGXNTOOL_ENABLE_TEST_INSTALL = yes
  else
    PGXNTOOL_ENABLE_TEST_INSTALL = no
  endif
endif

# ------------------------------------------------------------------------------
# verify-results: Safeguard for make results
# ------------------------------------------------------------------------------
# Purpose: Prevents accidentally running 'make results' when tests are failing.
#          Checks for existence of regression.diffs file before allowing results update.
#
# Variable: PGXNTOOL_ENABLE_VERIFY_RESULTS
#   - Can be set manually in Makefile or command line
#   - Allowed values: "yes" or "no" (case-insensitive)
#   - If not set: Defaults to "yes" (enabled by default for all pgxntool projects)
#   - Usage: Controls whether verify-results target exists and blocks make results
#
# Implementation: See verify-results target definition and results target modification
#                 (search for "verify-results" and "results:" in this file)
#
ifdef PGXNTOOL_ENABLE_VERIFY_RESULTS
  # User explicitly set the variable - validate and use their value
  PGXNTOOL_ENABLE_VERIFY_RESULTS_NORM = $(strip $(shell echo "$(PGXNTOOL_ENABLE_VERIFY_RESULTS)" | tr '[:upper:]' '[:lower:]'))
  ifneq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS_NORM),yes)
    ifneq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS_NORM),no)
      $(error PGXNTOOL_ENABLE_VERIFY_RESULTS must be "yes" or "no", got "$(PGXNTOOL_ENABLE_VERIFY_RESULTS)")
    endif
  endif
  # Use normalized value - use := for immediate evaluation to avoid recursion
  override PGXNTOOL_ENABLE_VERIFY_RESULTS := $(PGXNTOOL_ENABLE_VERIFY_RESULTS_NORM)
else
  # Auto-detect: default to yes (enabled by default for all pgxntool projects)
  PGXNTOOL_ENABLE_VERIFY_RESULTS = yes
endif

MODULES      = $(patsubst %.c,%,$(wildcard src/*.c))
ifeq ($(strip $(MODULES)),)
MODULES =# Set to NUL so PGXS doesn't puke
endif

EXTRA_CLEAN  = $(wildcard ../$(PGXN)-*.zip) $(EXTENSION_VERSION_FILES) $(TEST_SQL_FROM_SOURCE) $(TEST_EXPECTED_FROM_SOURCE)

# Get Postgres version, as well as major (9.4, etc) version.
# NOTE! In at least some versions, PGXS defines VERSION, so we intentionally don't use that variable
PGVERSION 	 = $(shell $(PG_CONFIG) --version | awk '{sub("(alpha|beta|devel).*", ""); print $$2}')
# Multiply by 10 is easiest way to handle version 10+
MAJORVER 	 = $(shell echo $(PGVERSION) | awk -F'.' '{if ($$1 >= 10) print $$1 * 10; else print $$1 * 10 + $$2}')

# Function for testing a condition
test		 = $(shell test $(1) $(2) $(3) && echo yes || echo no)

GE91		 = $(call test, $(MAJORVER), -ge, 91)

ifeq ($(GE91),yes)
all: $(EXTENSION_VERSION_FILES)
endif

ifeq ($($call test, $(MAJORVER), -lt 13), yes)
	REGRESS_OPTS += --load-language=plpgsql
endif

#
# Generate schedule file for test/install if enabled
#
# Why a schedule file is needed for test/install but not test/build:
# The point of test/install is to run setup (like extension installation) once,
# before all other tests, in the same database environment that the tests will use.
# The only way to run SQL in the same environment as pg_regress tests is through
# pg_regress itself. And the only way to control pg_regress execution order is
# via a schedule file. test/build doesn't need this because it runs independently
# through its own pg_regress invocation, not as part of the main test suite.
#
TEST_SCHEDULE_FILE = $(TESTDIR)/.schedule
ifeq ($(PGXNTOOL_ENABLE_TEST_INSTALL),yes)
PGXNTOOL_distclean += $(TEST_SCHEDULE_FILE)
TEST_INSTALL_REGRESS = $(sort $(notdir $(subst .source,,$(TEST_INSTALL_FILES:.sql=))))
# Schedule file lists test/install files first, then regular test files (but not test/build files)
# REGRESS already excludes test/build files since TEST_FILES doesn't include them
$(TEST_SCHEDULE_FILE): $(TEST_INSTALL_FILES) $(TEST_FILES) Makefile
	@echo "# Auto-generated schedule file - test/install runs before test/sql" > $@
	@for test in $(TEST_INSTALL_REGRESS); do echo "$$test" >> $@; done
	@for test in $(REGRESS); do echo "$$test" >> $@; done
REGRESS_OPTS += --schedule=$(TEST_SCHEDULE_FILE)
installcheck: $(TEST_SCHEDULE_FILE)
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
# Need to do this because we're not setting EXTENSION
MODULEDIR = extension
DATA += $(wildcard *.control)

# Don't have installcheck bomb on error
.IGNORE: installcheck
installcheck: $(TEST_RESULT_FILES) $(TEST_SQL_FILES) $(TEST_SOURCE_FILES) | $(TESTDIR)/sql/ $(TESTDIR)/expected/ $(TESTOUT)/results/

#
# TEST SUPPORT
#
# These targets are meant to make running tests easier.

# make test: run any test dependencies, then do a `make install installcheck`.
# If regressions are found, it will output them.
#
# This used to depend on clean as well, but that causes problems with
# watch-make if you're generating intermediate files. If tests end up needing
# clean it's an indication of a missing dependency anyway.
.PHONY: test
ifeq ($(PGXNTOOL_ENABLE_TEST_BUILD),yes)
test: testdeps test-build install installcheck
else
test: testdeps install installcheck
endif
	@if [ -r $(TESTOUT)/regression.diffs ]; then cat $(TESTOUT)/regression.diffs; fi

#
# verify-results: Safeguard for make results
#
# Checks if tests are passing before allowing make results to proceed
ifeq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS),yes)
.PHONY: verify-results
verify-results:
	@if [ -r $(TESTOUT)/regression.diffs ]; then \
		echo "ERROR: Tests are failing. Cannot run 'make results'."; \
		echo "Fix test failures first, then run 'make results'."; \
		echo ""; \
		echo "See $(TESTOUT)/regression.diffs for details:"; \
		cat $(TESTOUT)/regression.diffs; \
		exit 1; \
	fi
endif

# make results: runs `make test` and copy all result files to expected
# DO NOT RUN THIS UNLESS YOU'RE CERTAIN ALL YOUR TESTS ARE PASSING!
#
# pg_regress workflow:
# 1. Converts input/*.source → sql/*.sql (with token substitution)
# 2. Converts output/*.source → expected/*.out (with token substitution)
# 3. Runs tests, saving actual output in results/
# 4. Compares results/ with expected/
#
# NOTE: Both input/*.source and output/*.source are COMPLETELY OPTIONAL and are
# very rarely needed. pg_regress does NOT create the input/ or output/ directories
# - these are optional INPUT directories that users create if they need them.
# Most extensions will never need these directories.
#
# CRITICAL: Do NOT copy files that have corresponding output/*.source files, because
# those are the source of truth and will be regenerated by pg_regress from the .source files.
# Only copy files from results/ that don't have output/*.source counterparts.
.PHONY: results
ifeq ($(PGXNTOOL_ENABLE_VERIFY_RESULTS),yes)
results: verify-results test
else
results: test
endif
	@# Copy .out files from results/ to expected/, excluding those with output/*.source counterparts
	@# .out files with output/*.source counterparts are generated from .source files and should NOT be overwritten
	@$(PGXNTOOL_DIR)/make_results.sh $(TESTDIR) $(TESTOUT)

# testdeps is a generic dependency target that you can add targets to
.PHONY: testdeps
testdeps: pgtap

# These targets ensure all the relevant directories exist
$(TESTDIR)/sql $(TESTDIR)/expected/ $(TESTOUT)/results/:
	@mkdir -p $@
$(TEST_RESULT_FILES): | $(TESTDIR)/expected/
	@touch $@

#
# test-build: Sanity check extension files in test/build/
#
ifeq ($(PGXNTOOL_ENABLE_TEST_BUILD),yes)
TEST_BUILD_REGRESS = $(sort $(notdir $(subst .sql,,$(TEST_BUILD_FILES))))
TEST_BUILD_RESULT_FILES = $(patsubst $(TESTDIR)/build/%.sql,$(TESTDIR)/expected/%.out,$(TEST_BUILD_FILES))
.PHONY: test-build
test-build: install
	@if [ -z "$(strip $(TEST_BUILD_FILES))" ]; then \
		echo "No files found in $(TESTDIR)/build/"; \
		exit 1; \
	fi
	@mkdir -p $(TESTDIR)/expected
	@mkdir -p $(TESTDIR)/build/sql
	@for file in $(TEST_BUILD_FILES); do \
		basename_file=$$(basename $$file); \
		if [ ! -f "$(TESTDIR)/build/sql/$$basename_file" ]; then \
			cp "$$file" "$(TESTDIR)/build/sql/$$basename_file"; \
		fi; \
		if [ ! -f "$(TESTDIR)/expected/$$(basename $$file .sql).out" ]; then \
			touch "$(TESTDIR)/expected/$$(basename $$file .sql).out"; \
		fi; \
	done
	$(MAKE) -C . REGRESS="$(TEST_BUILD_REGRESS)" REGRESS_OPTS="--inputdir=$(TESTDIR)/build --outputdir=$(TESTOUT)" installcheck
	@if [ -r $(TESTOUT)/regression.diffs ]; then \
		echo "test-build failed - see $(TESTOUT)/regression.diffs"; \
		cat $(TESTOUT)/regression.diffs; \
		exit 1; \
	fi
endif


#
# DOC SUPPORT
#
ASCIIDOC_HTML += $(filter %.html,$(foreach ext,$(ASCIIDOC_EXTS),$(ASCIIDOC_FILES:.$(ext)=.html)))
DOCS_HTML += $(ASCIIDOC_HTML)

# General ASCIIDOC template. This will be used to create rules for all ASCIIDOC_EXTS
define ASCIIDOC_template
%.html: %.$(1)
ifeq (,$(strip $(ASCIIDOC)))
	$$(warning Could not find "asciidoc" or "asciidoctor". Add one of them to your PATH,)
	$$(warning or set ASCIIDOC to the correct location.)
	$$(error Could not build %$$@)
endif # ifeq ASCIIDOC
	$$(ASCIIDOC) $$(ASCIIDOC_FLAGS) $$<
endef # define ASCIIDOC_template

# Create the actual rules
$(foreach ext,$(ASCIIDOC_EXTS),$(eval $(call ASCIIDOC_template,$(ext))))

# Create the html target regardless of whether we have asciidoc, and make it a dependency of dist
html: $(ASCIIDOC_HTML)
dist: html

# But don't add it as an install or test dependency unless we do have asciidoc
ifneq (,$(strip $(ASCIIDOC)))

# Need to do this so install & co will pick up ALL targets. Unfortunately this can result in some duplication.
DOCS += $(ASCIIDOC_HTML)

# Also need to add html as a dep to all (which will get picked up by install & installcheck
all: html

endif # ASCIIDOC

.PHONY: docclean
docclean:
	$(RM) $(DOCS_HTML)


#
# TAGGING SUPPORT
#
rmtag:
	git fetch origin # Update our remotes
	@test -z "$$(git branch --list $(PGXNVERSION))" || git branch -d $(PGXNVERSION)
	@test -z "$$(git branch --list -r origin/$(PGXNVERSION))" || git push --delete origin $(PGXNVERSION)

# TODO: Don't puke if tag already exists *and is the same*
tag:
	@test -z "$$(git status --porcelain)" || (echo 'Untracked changes!'; echo; git status; exit 1)
	git branch $(PGXNVERSION)
	git push --set-upstream origin $(PGXNVERSION)

.PHONY: forcetag
forcetag: rmtag tag

.PHONY: dist
dist: tag dist-only

dist-only:
	@# Check if .gitattributes exists but isn't committed
	@if [ -f .gitattributes ] && ! git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then \
		echo "ERROR: .gitattributes exists but is not committed to git." >&2; \
		echo "       git archive only respects export-ignore for committed files." >&2; \
		echo "       Please commit .gitattributes for export-ignore to take effect." >&2; \
		exit 1; \
	fi
	git archive --prefix=$(PGXN)-$(PGXNVERSION)/ -o ../$(PGXN)-$(PGXNVERSION).zip $(PGXNVERSION)

.PHONY: forcedist
forcedist: forcetag dist

# Target to list all targets
# http://stackoverflow.com/questions/4219255/how-do-you-get-the-list-of-targets-in-a-makefile
.PHONY: no_targets__ list
no_targets__:
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true


#
# subtree sync support
#
# This is setup to allow any number of pull targets by defining special
# variables. pgxntool-sync-release is an example of this.
.PHONY: pgxn-sync-%
pgxntool-sync-%:
	git subtree pull -P pgxntool --squash -m "Pull pgxntool from $($@)" $($@)
pgxntool-sync: pgxntool-sync-release

# DANGER! Use these with caution. They may add extra crap to your history and
# could make resolving merges difficult!
pgxntool-sync-release	:= git@github.com:decibel/pgxntool.git release
pgxntool-sync-stable	:= git@github.com:decibel/pgxntool.git stable
pgxntool-sync-local		:= ../pgxntool release # Not the same as PGXNTOOL_DIR!
pgxntool-sync-local-stable	:= ../pgxntool stable # Not the same as PGXNTOOL_DIR!

distclean:
	rm -f $(PGXNTOOL_distclean)
	rm -f $(TESTDIR)/.schedule

ifndef PGXNTOOL_NO_PGXS_INCLUDE

ifeq (,$(strip $(DOCS)))
DOCS =# Set to NUL so PGXS doesn't puke
endif

include $(PGXS)
#
# Make clean also run distclean to remove PGXNTOOL_distclean files
# This must be after PGXS is included so we can add distclean as a prerequisite
clean: distclean

#
# pgtap
#
# NOTE! This currently MUST be after PGXS! The problem is that
# $(DESTDIR)$(datadir) aren't being expanded. This can probably change after
# the META handling stuff is it's own makefile.
#
.PHONY: pgtap
installcheck: pgtap
pgtap: $(DESTDIR)$(datadir)/extension/pgtap.control

$(DESTDIR)$(datadir)/extension/pgtap.control:
	pgxn install pgtap --sudo

endif # fndef PGXNTOOL_NO_PGXS_INCLUDE
