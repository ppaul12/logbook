# Logbook Git Commit Conventions

Use `{prefix}: {message}` for the commit subject. Use a lowercase prefix and put one space after the colon. Write the message as a short English phrase that starts with a capitalized imperative verb. Omit the trailing period. Aim for 72 characters or fewer, including the prefix.

```text
feat: Add strength training and optimize heatmaps
```

## Choosing a Prefix

Choose the prefix that reflects the primary purpose of the commit.

| Prefix | Use for | Example |
| --- | --- | --- |
| `feat` | Add or extend a user-facing feature | `feat: Add post-workout check-ins` |
| `fix` | Correct a bug, crash, or regression | `fix: Use the correct date for overnight check-ins` |
| `perf` | Improve responsiveness or reduce memory use or rendering cost | `perf: Draw only visible heatmap cells` |
| `refactor` | Restructure code while preserving observable behavior | `refactor: Share check-in editors across views` |
| `docs` | Update documentation or usage instructions | `docs: Document training backup compatibility` |
| `test` | Add or correct tests as a standalone change | `test: Cover heatmap date navigation` |
| `build` | Change dependencies, build settings, or packaging | `build: Update Xcode target settings` |
| `ci` | Change continuous integration workflows | `ci: Run Swift tests on macOS` |
| `chore` | Perform routine repository maintenance | `chore: Update ignore rules` |
| `revert` | Undo an earlier commit | `revert: Remove the new heatmap renderer` |

## Commit Body

The body is optional. Separate it from the subject with a blank line. Use it to explain the reason for the change, its user-visible effects, or compatibility considerations. When a change affects data migration, backup formats, or restore behavior, describe what is affected. To link a related issue, add a reference such as `Refs #123` at the end of the body.

## Splitting Commits

- Give each commit one purpose that can be reviewed and reverted independently.
- Include the tests, assets, and project configuration that a feature requires in the same `feat` commit.
- Put a performance improvement in its own commit when it can be verified and reverted independently. For example, use `feat: Add strength training` for the feature and `perf: Optimize heatmap rendering` for the standalone rendering change.
