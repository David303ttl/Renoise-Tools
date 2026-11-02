# ACID scale library

Scales with identical semitone membership share one entry. Alternate names are
searchable aliases.

Import UTF-8 `.txt` files with one definition per line:

```text
# Notes are semitone offsets from the selected root.
[Modes]
Dorian = 0 2 3 5 7 9 10
Mixolydian = 0, 2, 4, 5, 7, 9, 10

[Pentatonic]
Major Pentatonic = 0 2 4 7 9
```

Blank lines and lines beginning with `#` are ignored. A `[Category]` heading is
optional; definitions before the first heading use the `Custom` category.
Intervals may be separated with spaces or commas. Each scale must include root
`0`, and each interval must be a unique integer from `0` to `11`. Scale names
are limited to 64 bytes and categories to 48 bytes. Names cannot
begin with `#` or contain brackets; names and categories cannot contain control
characters. Files are limited to 256 KiB. If any line is invalid, the whole
file is rejected with its line number. UTF-8 BOM and CRLF files are supported.
