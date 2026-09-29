# Codex 一站式修复工具说明

Clone 地址：https://github.com/ChhY-bit/Codex-Fixer.git

> ## ⚠️ 核心原则：会话绑定模型，切走即失效
>
> **每个对话在创建时就绑定了当时的模型。切换 provider 后，绑定旧模型的会话无法续用：**
>
> - 官方模型（gpt-5.x）的会话 → 切到第三方后**永久不可续用**（继续对话需要官方模型、压缩要走官方端点，而官方额度已耗尽/登录已停用，双死）
> - 国产模型之间的切换（qwen ↔ GLM）→ 会话**通常可续用**，偶尔报"会话恢复失败"就重开
> - 第三方切回官方 → 可续用（官方能力是超集）
>
> **实操建议：官方额度快用完时，把重要的官方对话收尾（结论、代码落盘）；切国产后开新对话，需要旧上下文就手动贴关键内容。**

适用场景：通过 cc-switch 等工具为 Codex 接入第三方模型（qwen / GLM / DeepSeek 等）时遇到的常见问题。

## 文件清单

| 文件 | 说明 |
|---|---|
| `Codex修复工具.bat` | 双击运行的入口（仅 Windows） |
| `codex-doctor.ps1` | 实际逻辑脚本，跨平台（macOS/Linux 需 PowerShell Core，用 `pwsh codex-doctor.ps1` 运行） |
| `Codex修复说明.md` | 本文档 |

两个脚本文件需放在同一目录。脚本不含任何绝对路径硬编码，会自动定位用户目录下的 `.codex` 配置（也支持 `CODEX_HOME` 环境变量），可直接复制到其他设备使用。

## 三个问题及根因

### 问题 1：Codex 无法联网，但浏览器正常

**根因**：代理软件（如 Clash）只设置了 Windows 系统代理，浏览器走系统代理所以正常；但 Codex 只认 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量，不读系统代理，于是直连 OpenAI 失败。

**修复**：将代理地址写入用户级环境变量，并设置 `NO_PROXY` 排除本地回环。

### 问题 2：切换第三方模型后仍提示"额度用尽"、发送键失效

**根因**：cc-switch 切换供应商时会在 `~/.codex/config.toml` 中硬编码写入 `requires_openai_auth = true`，导致 Codex 把第三方供应商当作官方 OpenAI 认证路由，启动时仍对官方 ChatGPT 账号做额度检查，官方额度耗尽即被锁死（cc-switch 已知 Bug，issue #7490）。

**修复**：将该值改为 `false`，认证改由 `experimental_bearer_token`（代理托管）负责。

**注意**：每次在 cc-switch 里切换/重新应用供应商，此值都会被覆盖回 `true`，需重新运行脚本改回。切回官方时则相反，需改为 `true`。

### 问题 3：接续旧对话时自动压缩并报"使用上限"

**根因**：cc-switch 生成的模型目录把 `context_window` 写成 1,000,000，Codex 以为上下文无限大，从不提前压缩。旧对话历史滚大后，接续时的压缩请求一次性携带全部历史，要么超出模型/配额实际可承受的单请求规模，要么短时间内累计 token 撞上每分钟配额（TPM），Codex 把上游 429 错误误报为"额度用尽"。新对话因只有系统提示词（约 3 万 token）所以正常。

**修复**：把模型目录（`config.toml` 中 `model_catalog_json` 指向的文件）里所有模型的 `context_window` / `max_context_window` 调小（默认 262144，即 256k），让 Codex 在安全范围内提前压缩，避免单次请求过大或触发 TPM 累计限流。

**实测参考**（qwen3.8-flash，间隔单发）：约 5.5 万字符 17 秒成功、约 11 万字符（约 6 万 token）11 秒成功、约 40 万字符（约 20 万+ token）10 秒成功——单请求容量远超 32k，256k 是兼顾大对话与限流余量的取值。若日常仍频繁报"使用上限"，可在脚本选项 3 中调小（如 131072 或 65536）。

**注意**：同样会被 cc-switch 切换操作重新覆盖，需重跑脚本；已超过设定窗口的旧对话需开新对话。

### 问题 4：切换模型时报 "The 'xxx' model is not supported when using Codex with a ChatGPT account"

**根因**：`~/.codex/auth.json` 的 `auth_mode` 仍为 `chatgpt`（官方登录态未退出）。Codex 在 ChatGPT 账号模式下会按账号白名单校验模型，第三方模型（如 GLM）不在名单内即被拒绝。

**修复**：停用 `auth.json`（重命名为 `auth.json.disabled`，原文件备份为 `auth.json.official-backup`），让 Codex 走 API Key 认证逻辑，由 `experimental_bearer_token`（代理托管）负责鉴权。**官方登录已备份，切回官方时脚本会自动恢复，无需重新登录。**

**注意**：脚本的选项 2 已集成此逻辑——切第三方（false）自动停用并备份，切官方（true）自动从备份恢复。

### 问题 5：压缩时报 "Error running remote compact task: 401 Unauthorized ... api.openai.com"

**根因**：Codex 的压缩路径由**会话当时绑定的模型**决定：OpenAI 官方模型（gpt-5.x 系列）走"远程压缩"（OpenAI 服务端功能，端点硬编码为 api.openai.com，必须官方凭据）；第三方模型走"本地压缩"（直接调用当前 provider 做摘要，走 cc-switch 代理）。当会话绑定的是官方模型、而 `auth.json` 已停用（问题 4 的修复）时，远程压缩无凭据可用，即报此 401。

**修复**：无需改配置。将该会话的模型切换为第三方模型（qwen/GLM）后，压缩自动改走本地路径；或直接开新对话。**注**：官方额度已耗尽的账号即使恢复登录，远程压缩也会因额度问题失败，官方模型的旧会话在第三方模式下无法压缩续用。

### 问题 6：提示"无法发送消息 / 更新 Agent 沙盒以继续"

**根因**：Codex 桌面版的 Windows 沙盒（`elevated` 模式）需要管理员一次性提权设置（"完成 Windows 设置"向导：创建沙盒用户组、安装服务、修改 ACL）。设置失败时 `.codex\.sandbox\setup_error.json` 记录 `helper_sandbox_lock_failed`，Codex 禁用发送。**常见触发因素**：企业 EDR 安全软件（如深信服）拦截提权操作、沙盒组件版本更新、代理端口变化触发的防火墙规则重设。

**修复**（按序尝试）：

1. 将 `config.toml` 中 `[windows]` 段的 `sandbox = "elevated"` 改为 `"unelevated"`——无需提权设置，直接绕过向导，实测有效。防护强度略低（沙盒以普通权限运行）但仍具备文件系统/网络隔离；
2. 若必须用 elevated：结束 Codex 进程 → 重启沙盒服务 `CodexSandboxService.OpenAI.Codex`（需管理员）→ 删除 `setup_error.json` → 重新走向导；
3. 仍失败则检查 EDR 拦截日志或将 Codex 安装目录加白；最终兜底是备份后重置整个 `.codex` 目录。

脚本选项 5 集成了流程 1+2（检测到 elevated 时询问是否切换 unelevated）。

### 问题 7：切回官方后，国产模型的旧对话打不开，提示 "Model provider `custom` not found"

**根因**：Codex 会话在创建时就绑定了当时的 `model_provider` id（第三方模式下 cc-switch 写入的是 `custom`）。切回官方时，cc-switch 会把 `config.toml` 中的 `[model_providers.custom]` 段整体删除（替换为 `[model_providers.cc-switch-official]`），绑定第三方 provider 的旧会话加载时找不到定义，即报 "ChatGPT 无法加载 config.toml ... Model provider `custom` not found"，对话无法打开。

**修复**：在 `config.toml` 末尾补回一个 `[model_providers.custom]` 桩定义，指向 cc-switch 本地代理（`http://127.0.0.1:15721/v1`，代理接管模式下官方/第三方同走此地址），旧对话即可正常打开。

**注意**：

- 打开后可查看/导出历史；**续聊**请求会经 cc-switch 代理转发到**当前激活**的供应商——若当前是官方模式，旧对话续聊需在 cc-switch 中切回对应第三方供应商，否则会因模型不匹配报错；
- cc-switch 每次切换供应商都会重写 `config.toml` 并删除该段，切回官方后需重跑脚本；
- 脚本选项 3（切回官方）已自动附带此修复，也可单独运行选项 6。

## 使用方法

双击 `Codex修复工具.bat`，菜单按使用场景分组：

```
 通用 (官方 / 第三方模型都需要):
  [1] 检测并设置网络代理  -- Codex 无法联网时用这个

 仅第三方模型需要 (cc-switch 路由):
  [2] 第三方模式修复  -- 切到国产模型后 (额度提示/发送失效/GLM报错)
  [3] 切回官方模式    -- 恢复 ChatGPT 账号登录

 高级:
  [4] 自定义上下文窗口 (默认 256k，报"使用上限"时调小)
  [5] 修复 Agent 沙盒   -- 提示"更新 Agent 沙盒以继续/无法发送"时用
  [6] 修复旧对话打不开 -- 提示 "Model provider xxx not found" 时用
  [7] 刷新状态
  [8] 退出
```

主菜单上方会实时显示当前状态（认证模式、上下文窗口、代理变量、账号认证、配置路径），便于确认。

### 日常流程

1. **Codex 无法联网（无论用官方还是第三方模型）** → 运行脚本选 `1` → 重启 Codex（完全退出含托盘）
2. **官方额度耗尽，切国产模型** → cc-switch 切换 → 运行脚本选 `2`（有确认提示）→ 重启 Codex
3. **官方额度恢复，切回官方** → cc-switch 切换 → 运行脚本选 `3`（自动恢复官方登录 + 保留旧对话可打开）→ 重启 Codex
4. **提示"更新 Agent 沙盒以继续/无法发送"** → 运行脚本选 `5` → 重启 Codex
5. **国产模型的旧对话打不开（Model provider not found）** → 运行脚本选 `6` → 重启 Codex

### 脚本行为说明

- **代理检测**（选项 1）：先测试能否直连 `api.openai.com`，能直连则跳过；否则从系统注册表代理设置和常见本地端口（7897/7890/1080/10808 等）中探测可用代理，逐个验证通过后写入环境变量；探测不到时会提示手动输入
- **修改即时生效范围**：环境变量只对新启动的进程生效；config 修改需重启 Codex 生效
- **非 Windows 平台**：路径解析已兼容 `HOME` / `CODEX_HOME`，但环境变量写入可能需手动 `export`

## 排查记录（供参考）

- 代理可用性验证：直连 `api.openai.com:443` TCP 连接失败；走 `127.0.0.1:7897`（Clash）后 API 返回 401（连接正常，未带令牌的预期响应）
- 上游容量实测（qwen3.8-flash，间隔单发）：5.5 万字符 17s / 11 万字符 11s / 40 万字符 10s 均成功；早前一次 12 万字符"超时"经复核为瞬时网络故障，并非容量上限
- cc-switch 本地代理默认监听 `127.0.0.1:15721`，其日志位于 `~/.cc-switch/logs/cc-switch.log`
