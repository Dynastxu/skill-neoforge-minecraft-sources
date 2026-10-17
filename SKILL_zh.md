---
name: mc-sources
description: 检索 Minecraft 与 NeoForge 的反编译源码（直接流式读取 sources jar，不解压到工作区）。当需要确认原版类/方法/字段/事件/注册表/数据驱动内容的实现，或核对 NeoForge 补丁后的行为时加载。
---

# MC 源码检索

环境要求：使用 NeoForge ModDevGradle，Minecraft 源码已经由 NeoForm 反编译并映射好，位于 `build/moddev/artifacts/minecraft-patched-<mc>-sources.jar`：

原理：将 jar 作为 zip 流式读取。

## 命令

在项目根目录执行（脚本会自己定位最近的 Gradle 项目根：同时含 `.git` 与 `settings.gradle`/`settings.gradle.kts`/`gradle.properties` 的目录；找不到时退回当前目录）：

```powershell
pwsh -NoProfile -File path/to/scripts/mcsrc.ps1 <命令> [参数]
```

- `info`：jar 路径、版本、条目数、NeoForge jar
- `find <regex>`：按类名找类，输出全限定名
- `grep <regex>`：查找正文，按文件分组输出（路径只在文件头出现一次）
- `show <类>`：打印单个类（默认前 600 行）
- `list [<前缀>]`：列出包/类

### 通用参数：

- `-Path <包前缀>`：只搜某个包，支持全路径或片段（`net/minecraft/world/level/block` 或 `world/level/block`）。
- `-Context N`：grep 时带前后 N 行。
- `-Max N` / `-All`：限制/取消结果上限（默认 40）。
- `-Lines 40-80` / `-Full`：show 的行范围 / 不截断。
- `-Source neoforge`：改搜 NeoForge 自身源码（事件、Hook、补丁逻辑）。
- `-CaseSensitive`：区分大小写。

### grep 输出格式

按文件分组，长路径只在文件头写一次：

- `行号:` 是命中行，`行号-` 是 `-Context` 带出的上下文行；
- `...` 只在带 `-Context` 时出现，表示两段结果之间省略的行；不带 `-Context` 时命中行连续列出，行号跳变即表示省略；
- 文件头里的路径可直接传给 `show`。

## 使用规则

1. **先窄后宽**：先 `find` 或带 `-Path` 的 `grep`，确认类后再 `show` 对应行段；不要一上来打印整个大类。
2. **引用格式**：路径取文件头、行号取行首；回答里拼成 `net/minecraft/world/level/block/TntBlock.java:33` 这样的路径:行号，并说明是“原版实现”还是“NeoForge 补丁后”。
3. **show 默认截断**到 600 行；大文件（如 `Blocks.java`）用 `-Lines` 取需要的段。
4. **同名类**（如多个 `Block`）用全限定名；只给简单名时脚本会列出候选并报错。
5. **jar 不存在**：说明 ModDevGradle 还没生成，先跑一次 `.\gradlew.bat build`（或让 IDE 重新同步 Gradle），不要尝试自己反编译。
6. **只读沙箱**：`read-only` 模式下 `.NET` 不可用，脚本自动退回 `tar`，此时 `grep` 必须带 `-Path`（否则会拒绝执行）。

## 示例

- “TNT 怎么变成 PrimedTnt 的” → `grep "PrimedTnt" -Path world/level/block -Context 2`
- “某个注册表项在哪注册” → `grep "Registry.register" -Path world/level/block -Max 20`
- “NeoForge 的某个事件在哪触发” → `grep "SomeEvent" -Source neoforge -Max 20`
- “这个类有哪些方法” → `show <类> -Lines 1-200`

如果脚本输出 `mcsrc: ...` 并以非零码退出，把该消息原样转述，不要猜测源码内容。
