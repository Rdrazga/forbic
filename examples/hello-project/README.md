# hello-project: a sample Forbic project

A project is a directory with a manifest, `forbic.json`, naming its root module, and its sources
under `src/`, one folder per module ([RFC-0095](../../docs/rfcs/0095-project-layout.md)):

- `forbic.json`: `{"root": "/hello@example.com/Hello"}`.
- `src/hello@example.com/Hello/`: the root module, two files read as one in the order of their
  names. `main.forb` imports the other module by its path and declares `Greeting`;
  `visits.forb` uses `Greeting` without an import and counts visits in a persistent cell.
- `src/hello@example.com/Text/greet.forb`: the module `/hello@example.com/Text`.

From the package root (the `forbic/` directory):

```text
$ forbic check examples/hello-project
ok: 4 bindings, 20 typed nodes
$ forbic run examples/hello-project
Hello, world! (visit 0)
{"Greeting":"Hello, world!","Visits":[],"Visit":0,"Shown":[]}
$ forbic run examples/hello-project --key visitor --state my-state
Hello, world! (visit 1)
...
$ forbic run examples/hello-project --key visitor --state my-state
Hello, world! (visit 2)
...
```

Without `--key visitor` the program has no key to count by; with the key but no `--state`, each
run counts its own first visit and keeps nothing. The package's `integration` step runs these
commands and compares their output.
