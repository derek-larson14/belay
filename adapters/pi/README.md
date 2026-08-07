# Pi adapter

Thin bridge: Pi `tool_call` → `bridge.sh` → `belay.sh` (shared core).

```bash
./belay install pi          # links this dir to ~/.pi/agent/extensions/belay
./adapters/pi/test-bridge.sh
```

Not a separate product — the same guards and the same config the other harnesses
use. Config resolves through `<project>/.belay.toml` then `~/.belay/config.toml`;
no `CLAUDE_PROJECT_DIR` needed, the project root is found by walking up for
`.belay.toml` or `.git`.
