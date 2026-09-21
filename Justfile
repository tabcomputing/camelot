# Generate GObject-Introspection bindings (Atspi) — needed once after `shards install`.
bindings:
    shards install
    bin/gi-crystal

build:
    shards build

release:
    shards build --release

spec:
    crystal spec

run *ARGS:
    crystal run src/cli.cr -- {{ARGS}}
