<!-- Thanks for the pull request. For anything bigger than a small fix, please open an issue first.
     The guide: https://github.com/efim0v/brow/blob/main/CONTRIBUTING.md -->

## What and why

<!-- What does this change, and why? Link the issue it closes, e.g. "Fixes #12". -->

## How it was tested

<!-- Commands you ran. For a visible change: the Mac model, and a screenshot or recording. -->

- [ ] `Scripts/test-in-empty-home.sh` passes (the whole suite, with the home folder pointed at an empty one)
- [ ] `Scripts/test-in-empty-home.sh -c release` passes
- [ ] Tests added or updated for changed behaviour
- [ ] UI change: screenshots attached (`swift run BrowApp --snapshot <dir>` renders the Workspaces screens)
- [ ] README or `docs/` updated where behaviour changed

## Worth flagging

- [ ] No token is logged, written to disk or sent anywhere but Anthropic's usage and profile endpoints
- [ ] Changes what Brow writes to Claude Code's files, and the README's "What Brow does on your machine" is updated to match
