# Coverage runner fixtures

Every file here is a coverage summary as a real runner prints it. They exist
because `coverage-gate.sh` parses five ecosystems and, until these were
captured, four of the five parsers had never seen genuine output — they were
written against remembered formats. Three of them were wrong.

Provenance is recorded per file, and it matters: a fixture I typed from memory
tests my memory, not the parser.

| Fixture | Provenance |
|---|---|
| `istanbul.txt` | **captured** — `npx c8 --reporter=text node test.mjs`, c8 10.x / Node 22.16 |
| `coveragepy.txt` | **captured** — `pytest --cov=pkg --cov-report=term -q`, coverage 7.16 / Python 3.13 |
| `go-single.txt` | **captured** — `go test -cover ./...`, go1.23.4, one package |
| `go-multi.txt` | **captured** — `go test -cover ./...`, go1.23.4, two packages |
| `go-func.txt` | **captured** — `go tool cover -func=c.out`, go1.23.4, same two packages |
| `pest.txt` | **derived from source** — `pestphp/pest` `src/Support/Coverage.php` renders `Total: {n} %` |
| `phpunit.txt` | **derived from source** — `sebastianbergmann/php-code-coverage` `src/Report/Text.php` `'  Lines:    %6s (%d/%d)'` |
| `simplecov.txt` | **derived from source** — `simplecov` `lib/simplecov/formatter/base.rb` `"%<label>s coverage: %<covered>d / %<total>d (%<percent>s)"` |
| `simplecov-simpleformatter.txt` | **derived from source** — `lib/simplecov/formatter/simple_formatter.rb`, per-file only, **no total** |

The three "derived from source" fixtures could not be captured on the machine
these were written on: no Ruby, and no `xdebug`/`pcov` on the available PHP, so
PHP coverage cannot be produced at all. They are built from the runner's own
`sprintf`/`format` string rather than from recollection, which is the closest
thing to a capture that was available. If you can run one of these for real,
replace the fixture with the capture and move its row.

## Why each fixture has a decoy

A coverage parser has exactly one interesting failure: reading **some** number
rather than **the total**. So every fixture keeps the per-file rows a real run
prints, and at least one of those rows is deliberately *higher* than the total.
A parser that grabs the last percentage it sees passes a fixture that has only
a total, and fails these.
