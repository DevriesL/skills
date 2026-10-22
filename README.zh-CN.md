# Skills

[English](README.md)

我在日常工作中使用的实用 Agent Skills。每个 skill 独立存放、可以单独安装；仓库会持续加入其它技能，WSL 工作流只是第一个。

## 技能目录

| Skill | 用途 | 环境要求 |
| --- | --- | --- |
| [wezterm-wsl](skills/wezterm-wsl/SKILL.md) | 在 Windows 上通过 WezTerm 操作持久化 WSL Shell，返回精简结果，并通过完成通知减少轮询。 | Windows、PowerShell 7+、WezTerm、带 Bash/coreutils 的 WSL；文件操作需要 Python 3，grep/glob 需要 ripgrep |

`wezterm-wsl` 保留了一个明确约定：当 Agent 可以使用它时，**涉及 WSL 的实际操作默认使用这套工作流，无需每次点名**。用户明确指定其它方式时，以用户要求为准。单纯回答 WSL 问题不会打开终端；需要在 Windows 侧管理 WSL 时，可以使用相应的 Windows 工具。

## 单独安装一个 skill

安装 Node.js/npm 后，可以使用 [skills CLI](https://github.com/vercel-labs/skills) 查看目录或安装指定技能：

```bash
npx skills add DevriesL/skills --list
npx skills add DevriesL/skills --skill wezterm-wsl -a codex -g
```

请在 **Agent 实际运行的环境** 中执行安装。若 Agent 运行在 Windows 上，就在 Windows 中安装；之后由 PowerShell helper 通过 WezTerm 操作 WSL。去掉 `-g` 可以改为项目级安装。目前实际验证的是 Windows 上的 Codex；能安装到其它 Agent 不代表已经验证兼容性。

也可以直接告诉 Codex：

```text
用 $skill-installer 安装 DevriesL/skills 仓库中的 skills/wezterm-wsl。
```

安装后开始一个新的 Agent 会话，即可说“请在 WSL 中查看当前目录和 Git 状态”。Agent 会按 skill 中的流程发现并绑定终端。WezTerm 和 WSL 发行版需要预先安装。

## 通过 Codex marketplace 安装整个合集

仓库同时提供名为 `devries-skills` 的 marketplace 和同名 plugin。该 plugin 包含 `skills/` 下的全部技能；只需要部分技能时，使用上面的单独安装方式。两种安装方式选一种，避免重复加载。

在支持插件市场的 Codex CLI 中执行：

```bash
codex plugin marketplace add DevriesL/skills
codex plugin add devries-skills@devries-skills
```

安装后开始新会话。Marketplace 支持情况取决于 Codex 版本和使用入口，也可以选择单独安装 skill。这是仓库提供的市场源，并不代表已上架 OpenAI 公共插件目录。参见[官方插件文档](https://developers.openai.com/plugins/build/plugins)。

## 简短的命令与文件接口

按 [skill 说明](skills/wezterm-wsl/SKILL.md) 绑定 WezTerm 会话后，运行已安装的 `scripts/wsl.ps1 init`，生成当前任务的 `work/wsl.ps1` 短启动器。它会记住会话绑定，无需修改 PATH 或 Shell 配置。

```powershell
& .\work\wsl.ps1 exec 'git status --short' -Cwd /home/user/project
& .\work\wsl.ps1 cd /home/user/project
& .\work\wsl.ps1 ls -All
& .\work\wsl.ps1 glob '**/*.py' -Root src
& .\work\wsl.ps1 grep 'TODO|FIXME' -Root src -Glob '*.py' -Limit 30
& .\work\wsl.ps1 read src/app.py -From 1 -Lines 80
& .\work\wsl.ps1 write notes.txt -Content 'Hello'
& .\work\wsl.ps1 edit notes.txt -Old 'Hello' -New 'Hello world'
& .\work\wsl.ps1 mv notes.txt -To archive/notes.txt -Parents
```

`grep` 搜索文件内容，返回路径、行号和匹配文本；`glob` 按模式查找文件。两者达到条数或字符上限就停止搜索，使用 WSL 中的 ripgrep（PATH 上的 `rg` 或 `~/.local/bin/rg`）。`-Root` 指定搜索范围，`-Glob` 过滤文件；grep 支持 `-Literal` 字面量和 `-IgnoreCase` 忽略大小写。忽略规则和显式 glob 的行为见[搜索参考](skills/wezterm-wsl/references/files.md#searching)。

`exec` 继续支持任意非交互 Bash 命令。文件接口直接在 WSL 中操作，保留已有 Linux 权限和一致的 CRLF 换行格式，并返回有长度限制的可读结果。`write`、`mv` 默认拒绝覆盖，`edit` 默认要求唯一匹配；使用 `read` 返回的 `-ExpectedHash` 可以拒绝基于旧内容的修改。程序消费结果时可加 `-Json`。完整参数见[文件 API 参考](skills/wezterm-wsl/references/files.md)。

## wezterm-wsl 如何工作

Windows PowerShell helper 绑定 WezTerm 中选定的空闲 Bash 提示符。命令在同一个 Shell 中运行，因此工作目录、变量和函数可以延续。普通命令返回精简 JSON，包含退出码、当前目录、标准输出和错误输出；用户仍能在终端看到输出。

长任务返回任务 ID，后续通过 `Wait` 获取增量结果。等待主要使用完成文件的通知，并辅以本地文件检查，无需反复截取终端文字。较长输出会在响应中截断，同时保留完整日志。

`scripts/run-driver.bash` 是每个任务使用的模板：它在选定的 Bash 中执行命令，通过 `tee` 同时显示和保存输出，等待日志写完后生成完成标记。无需常驻服务，也无需修改 Shell 配置文件。

会话持续时间取决于 WezTerm 窗格和 WSL Shell 是否仍然存活。交互程序使用独立的[交互操作流程](skills/wezterm-wsl/references/interactive.md)。命令、日志和会话状态默认保存在 Windows 工作目录的 `work/wezterm-wsl` 中，不要把凭据写入命令文本，也不要提交这些运行记录。

## 添加其它 skill

1. 新建 `skills/<skill-name>/SKILL.md`，包含 YAML `name`、`description` 字段和聚焦的操作说明。
2. 按需添加 `scripts/`、`references/`、`assets/` 或 `agents/`。引用使用相对路径，本机路径尽量在运行时发现。
3. 写明环境要求，验证实际工作流，并更新两个 README 的技能目录。
4. 发布合集更新时递增 `plugin.json` 的版本。Plugin 会发现 `skills/` 中的技能，因此新增 skill 无需增加 marketplace 条目。

```text
skills/
  wezterm-wsl/
    SKILL.md
    agents/
    references/
    scripts/
  another-skill/
    SKILL.md
```

## 验证

在 Linux/WSL 中运行文件操作测试：

```bash
python3 -m unittest discover -s tests -v
```

Windows 端到端测试需要 PowerShell 7、WezTerm 和已绑定的会话。从 Windows 检出目录运行 `tests/test_bridge.ps1 -Entry 已安装的scripts/wsl.ps1路径`，并使用与 Attach 相同的 `-StateRoot`。测试会在隔离的 WSL 临时目录中验证实际传输、Shell 状态、文件操作和增量等待。

## 许可证

[MIT](LICENSE)
