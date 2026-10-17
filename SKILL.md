---
name: mc-sources
description: Retrieve decompiled sources for Minecraft and NeoForge (stream-read the sources jar directly without extracting it into the workspace). Load when you need to confirm the implementation of vanilla classes/methods/fields/events/registries/data-driven content, or verify NeoForge-patched behavior.
---

# MC Source Search

Environment requirement: Use NeoForge ModDevGradle. Minecraft sources have already been decompiled and mapped by NeoForm, and are located at `build/moddev/artifacts/minecraft-patched-<mc>-sources.jar`:

Principle: Read the jar as a zip stream.

## Commands

Run in the project root directory (the script locates the project root by the nearest `.git`):

```powershell
pwsh -NoProfile -File path/to/scripts/mcsrc.ps1 <command> [arguments]
```

- `info`: jar path, version, entry count, NeoForge jar
- `find <regex>`: Find classes by class name; output fully qualified names
- `grep <regex>`: Search file contents; output grouped by file (path appears only once in the file header)
- `show <class>`: Print a single class (first 600 lines by default)
- `list [<prefix>]`: List packages/classes

### Common parameters:

- `-Path <package-prefix>`: Search only a certain package; supports full paths or fragments (`net/minecraft/world/level/block` or `world/level/block`).
- `-Context N`: Include N lines before and after when grepping.
- `-Max N` / `-All`: Limit/remove the result cap (default 40).
- `-Lines 40-80` / `-Full`: Line range for show / do not truncate.
- `-Source neoforge`: Search NeoForge's own sources instead (events, hooks, patch logic).
- `-CaseSensitive`: Case-sensitive.

### grep Output Format

Grouped by file; the long path appears only once in the file header:

- `line-number:` marks a matching line, and `line-number-` marks a context line included by `-Context`;
- `...` appears only with `-Context`, indicating omitted lines between two result sections; without `-Context`, matching lines are listed consecutively, and a jump in line numbers indicates omission;
- Paths in the file header can be passed directly to `show`.

## Usage Rules

1. **Narrow first, then broad**: First use `find` or `grep` with `-Path` to confirm the class, then `show` the relevant line range; do not print an entire large class right away.
2. **Citation format**: Take the path from the file header and the line number from the start of the line; in answers, combine them into a path:line like `net/minecraft/world/level/block/TntBlock.java:33`, and state whether it is the "vanilla implementation" or "NeoForge patched behavior".
3. **show truncates to 600 lines by default**; for large files (such as `Blocks.java`), use `-Lines` to get the needed section.
4. **For classes with the same name** (such as multiple `Block`s), use fully qualified names; if only a simple name is given, the script will list candidates and report an error.
5. **If the jar does not exist**: Indicate that ModDevGradle has not generated it yet; first run `.\gradlew.bat build` (or let the IDE resync Gradle), and do not try to decompile it yourself.
6. **Read-only sandbox**: In `read-only` mode, `.NET` is unavailable, and the script automatically falls back to `tar`; in this case, `grep` must include `-Path` (otherwise execution is refused).

## Examples

- "How does TNT become PrimedTnt" → `grep "PrimedTnt" -Path world/level/block -Context 2`
- "Where is a certain registry entry registered" → `grep "Registry.register" -Path world/level/block -Max 20`
- "Where is a certain NeoForge event triggered" → `grep "SomeEvent" -Source neoforge -Max 20`
- "What methods does this class have" → `show <class> -Lines 1-200`

If the script outputs `mcsrc: ...` and exits with a non-zero code, relay the message verbatim; do not guess the source contents.
