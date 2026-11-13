# GHAS alert triage (sprint 2026-11)

Open GitHub Advanced Security code-scanning alerts reviewed for this sprint. Nothing was dismissed on GitHub. There is no accepted alert, so no dismissal reason is recommended.

| Type | Number | Rule | Path | Disposition | Reason |
| --- | --- | --- | --- | --- | --- |
| code-scanning | 1 | js/polynomial-redos | dev/fake-gitlab.mjs | fixed | The `Bearer` header is read with a single forward pass, so a long run of spaces cannot make matching polynomial. |
| code-scanning | 2 | js/polynomial-redos | dev/fake-github.mjs | fixed | The `Bearer` and `token` schemes share that same linear reader. |
| code-scanning | 3 | js/bad-tag-filter | tests/BrowserSyntax.Tests.cjs | fixed | Script elements are found by a scan that accepts end tags such as `</script >`, which the old expression missed. |
| code-scanning | 4 | js/incomplete-multi-character-sanitization | tools/gen-icons.mjs | fixed | SVG comments are removed by a repeating scan, so cutting one comment cannot leave a new `<!--`. |
| code-scanning | 5 | js/xss-through-exception | dev/fake-gitlab.mjs | fixed | JSON bodies escape `<`, `>` and `&`, and JSON responses send `X-Content-Type-Options: nosniff`, so exception text is not raw HTML. |
