# Ultimate setup for KeyScribe

- **Worktree setup** (`worktree-setup.sh`): every branch works in its own git worktree with its own
  `.build`. That way no branch's build waits on the SwiftPM lock in another checkout. The script uses APFS
  copy-on-write to clone the source checkout's fetched dependencies (`repositories`, `checkouts`,
  `artifacts`), so `swift test` starts without refetching anything. Compiling still starts cold.
- **Lander**: runs `make test` (with a timeout) before fast-forwarding `main`. It never pushes.
