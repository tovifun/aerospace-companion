.PHONY: build test install uninstall clean

build:
	./scripts/build.sh

test:
	./scripts/test.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

clean:
	rm -rf build
