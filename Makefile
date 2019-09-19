SHELL = /bin/bash

export GOPATH := $(shell pwd)/gopath

PEBBLE_PATH = $(GOPATH)/src/github.com/letsencrypt/pebble
HS = $(shell find src/ test/ -name '*.hs')

.PHONY: $(HS)

pebble: pebble-get pebble-install

pebble-get:
	go get -d -u github.com/letsencrypt/pebble/...

pebble-install:
	cd $(PEBBLE_PATH); go install ./...

format-code: $(HS)

$(HS):
	-@hindent --sort-imports $@
	-@hlint -j --no-summary $@

