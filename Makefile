EMACS ?= emacs
PACKAGE_DIR ?= $(CURDIR)/.packages

PACKAGE_SETUP := test/package-setup.el
BATCH := FLEXI_TABLE_PACKAGE_DIR=$(PACKAGE_DIR) $(EMACS) -Q --batch \
	-l $(PACKAGE_SETUP) -L .

.PHONY: all check deps compile test lint checkdoc package-lint clean

all: check

check: compile test lint

deps:
	FLEXI_TABLE_PACKAGE_DIR=$(PACKAGE_DIR) \
	FLEXI_TABLE_INSTALL_DEPS=1 \
	FLEXI_TABLE_DEV_DEPS=1 \
	$(EMACS) -Q --batch -l $(PACKAGE_SETUP)

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile flexi-table.el

test:
	$(BATCH) -L test -l test/flexi-table-test.el \
		-f ert-run-tests-batch-and-exit

lint: checkdoc package-lint

checkdoc:
	$(BATCH) --eval \
		'(progn (require (quote checkdoc)) (checkdoc-file "flexi-table.el"))'

package-lint:
	$(BATCH) -l package-lint -f package-lint-batch-and-exit flexi-table.el

clean:
	$(RM) flexi-table.elc test/*.elc
