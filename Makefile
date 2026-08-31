.PHONY: all build test coverage mutants race format icon app run clean lint lint-strings

all: build

build:
	swift build

test:
	swift test

# Line coverage per file, worst first. Reported, never gated — see the script.
coverage:
	./scripts/coverage.sh

# Whether the tests would CATCH a bug, which coverage cannot tell you: change
# an operator, run the suite, see if anything fails. Slow — run it on the
# files a change touches, e.g. `make mutants FILES=Sources/.../Foo.swift`.
mutants:
	./scripts/mutants.sh $(FILES)

# The suite under ThreadSanitizer. Slower, so it is not part of `test`, but
# clipboard capture hashes and thumbnails off the main actor and Store
# serialises those captures by hand: that is the kind of code where a race
# reproduces on a user's machine and never on yours.
race:
	swift test --sanitize=thread

lint: lint-strings
	swift format lint --strict --recursive Sources Tests

# Key parity across the four .lproj files. Cheap enough to keep inside `lint`.
lint-strings:
	./scripts/check-localization.sh

format:
	swift format --in-place --recursive Sources Tests

icon:
	swift scripts/generate-icon.swift

app:
	./build.sh

run:
	./build.sh
	@# `open` on a running app reuses the old process; kill it so the fresh binary launches.
	-pkill -x Backpocket
	open build/Backpocket.app

clean:
	rm -rf .build build
