# Developer onboarding deck

[`slides.md`](slides.md) is a [Marp](https://marp.app) deck that introduces
new developers to ExitOS: what the appliance does, how the repository is laid
out, the dev loop, the runtime design and how changes ship. It summarises
[architecture.md](../architecture.md), [build.md](../build.md) and
[roadmap.md](../roadmap.md); when those change, update the deck with them.

On GitHub the file reads as plain Markdown. To present it:

```sh
nix run nixpkgs#marp-cli -- --preview docs/intro/slides.md     # presenter window
nix run nixpkgs#marp-cli -- docs/intro/slides.md -o slides.html # standalone HTML
nix run nixpkgs#marp-cli -- docs/intro/slides.md --pdf          # PDF; needs Chrome
```

The Marp extension for VS Code previews and exports it as well.
