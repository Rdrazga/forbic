# forbic-example: an orders service that embeds Forbic

A small Zig application built on the embedding API (the `forbic_embed` module,
`src/embed/forbic_embed.zig` in the `forbic/` package) and nothing else of the repository. It is the
companion of [the embedding guide](../../docs/embedding.md).

- `orders.forb` is the policy: each request line `CUSTOMER REGION QUANTITY UNIT_PRICE` becomes
  an order whose total includes the region's tax; each customer's record (orders, amount spent)
  is a persistent cell keyed by the customer's persistent key. A malformed line, an unknown
  region or a customer without a key is refused, and changes nothing.
- `main.zig` is the host. It registers one native, `orders.tax_rate`, which reads the host's
  tax table through its context; compiles and prepares the program once; quotes the batch in
  memory (a run whose store is empty and saves nothing); then serves the batch as a durable run
  that keeps the records in `WORK_DIR/state`.

Run it twice on one directory (it is created when it does not exist), from the `forbic/` package:

```sh
zig build forbic-example -- zig-out/forbic-example
zig build forbic-example -- zig-out/forbic-example
```

The quote is the same each time. The orders of the second run start from the records the first
run kept: `acme` has 3 and then 4 orders, `globex` 2. The package's `forbic-example-scenario` step
(part of the package's `zig build integration`) runs this scenario on a fresh temporary directory and
compares the output with the package's `tests/forbic-example/first.txt` and `second.txt`. Delete
the directory to start again; `forbic store show WORK_DIR/state` prints the records, and
`forbic journal show WORK_DIR/state` the last run's journal.
