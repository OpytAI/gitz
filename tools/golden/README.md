# Golden tools

`run_goldens.py` compares committed inputs and expected results under
`data/goldens/`. Bazel invokes it through `//check:goldens_smoke`.

`//tools/golden:recompute_test` rebuilds selected golden payloads through the
library APIs and compares them with committed expected results.

```bash
bazel test //check:goldens_smoke //tools/golden:recompute_test
```

Default tests must not depend on the network or a host Go installation.

## Refresh expected results

1. Extract behavior from tests in the pinned go-git checkout, or use a small
   offline oracle that imports that exact revision.
2. Write the updated result under `data/goldens/`.
3. Review the diff and commit the expected result with the related change.
4. Run the Bazel golden and recomputation tests.

Never refresh expected results automatically in the default test suite. Never
download fixtures during a build or test.
