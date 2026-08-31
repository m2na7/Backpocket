# What and why

<!-- What changes and the problem it solves. Link the issue if one exists. -->

# How it was verified

<!-- `make test` result. For UI changes, before/after screenshots — DEBUG builds
accept launch flags (--open, --query=, --settings, --settings-tab=, --edit,
--demo, --store=, --stack=N, --snapshot=) to drive the panel into a
reproducible state for capture.

--snapshot= captures whichever window the flags opened: the main panel, the
note editor with --edit, or a Settings pane with --settings --settings-tab=N
(--settings wins if both are passed). The Settings shot includes the toolbar,
so the highlighted tab is visible in the image. See CONTRIBUTING.md. -->

# Checklist

Per [CONTRIBUTING.md](https://github.com/m2na7/Backpocket/blob/main/CONTRIBUTING.md):

- [ ] `make test` passes
- [ ] `make lint` passes (formatting and `.lproj` key parity)
- [ ] The change comes with a test, or the PR says why it cannot have one
- [ ] `CHANGELOG.md` updated if the change is user-visible
- [ ] Comments explain why, not what
- [ ] No new dependencies
- [ ] User-visible strings landed in all four `.lproj` files (en, ko, ja, zh-Hans)
