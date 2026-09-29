# Codex-Fixer：Codex 一站式修复工具

面向 Windows 用户的 OpenAI Codex 桌面版故障修复工具，专注于解决通过 cc-switch 等工具为 Codex 接入第三方模型（qwen / GLM / DeepSeek 等）时遇到的常见问题。

> ## ⚠️ 核心原则：会话绑定模型，切走即失效
>
> **每个对话在创建时就绑定了当时的模型。切换 provider 后，绑定旧模型的会话无法续用：**
>
> - 官方模型（gpt-5.x）的会话 → 切到第三方后**永久不可续用**（继续对话需要官方模型、压缩要走官方端点，而官方额度已耗尽/登录已停用，双死）
> - 国产模型之间的切换（qwen ↔ GLM）→ 会话**通常可续用**，偶尔报"会话恢复失败"就重开
> - 第三方切回官方 → 可续用（官方能力是超集）
>
> **实操建议：官方额度快用完时，把重要的官方对话收尾（结论、代码落盘）；切国产后开新对话，需要旧上下文就手动贴关键内容。**

## 文件清单

| 文件 | 说明 |
|---|---|
| `Codex修复工具.bat` | 双击运行的入口（仅 Windows） |
| `codex-doctor.ps1` | 实际逻辑脚本，跨平台（macOS/Linux 需 PowerShell Core，用 `pwsh codex-doctor.ps1` 运行） |
| `Codex修复说明.md` | 详细文档：根因分析、使用指南、排查记录 |

两个脚本文件需放在同一目录。脚本不含任何绝对路径硬编码，会自动定位用户目录下的 `.codex` 配置（也支持 `CODEX_HOME` 环境变量），可直接复制到其他设备使用。

## 解决的问题

### 问题 1：Codex 无法联网，但浏览器正常

**根因**：代理软件（如 Clash）只设置了 Windows 系统代理，浏览器走系统代理所以正常；但 Codex 只认 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量，不读系统代理，于是直连 OpenAI 失败。

**修复**：将代理地址写入用户级环境变量，并设置 `NO_PROXY` 排除本地回环。脚本会先测试直连，再从系统注册表和常见本地端口（7897/7890/1080/10808 等）探测可用代理，逐个验证后写入。

### 问题 2：切换第三方模型后仍提示"额度用尽"、发送键失效

**根因**：cc-switch 切换供应商时会在 `~/.codex/config.toml` 中硬编码写入 `requires_openai_auth = true`，导致 Codex 把第三方供应商当作官方 OpenAI 认证路由，启动时仍对官方 ChatGPT 账号做额度检查（cc-switch 已知 Bug，issue #7490）。

**修复**：将该值改为 `false`，认证改由 `experimental_bearer_token`（代理托管）负责。

**注意**：每次在 cc-switch 里切换/重新应用供应商，此值都会被覆盖回 `true`，需重新运行脚本改回。切回官方时则相反，需改为 `true`。

### 问题 3：接续旧对话时自动压缩并报"使用上限"

**根因**：cc-switch 生成的模型目录把 `context_window` 写成 1,000,000，Codex 以为上下文无限大，从不提前压缩。旧对话历史滚大后，接续时的压缩请求一次性携带全部历史，超出模型/配额实际可承受的单请求规模，或短时间内累计 token 撞上每分钟配额（TPM），Codex 把上游 429 错误误报为"额度用尽"。

**修复**：把模型目录（`config.toml` 中 `model_catalog_json` 指向的文件）里所有模型的 `context_window` / `max_context_window` 调小（默认 262144，即 256k）。若日常仍频繁报"使用上限"，可调小至 131072 或 65536。

### 问题 4：切换模型时报 "The 'xxx' model is not supported when using Codex with a ChatGPT account"

**根因**：`~/.codex/auth.json` 的 `auth_mode` 仍为 `chatgpt`。Codex 在 ChatGPT 账号模式下按账号白名单校验模型，第三方模型不在名单内即被拒绝。

**修复**：停用 `auth.json`（重命名备份），让 Codex 走 API Key 认证。**官方登录已备份，切回官方时脚本会自动恢复，无需重新登录。** 脚本选项 2 / 3 已集成此逻辑。

### 问题 5：压缩时报 "Error running remote compact task: 401 Unauthorized ... api.openai.com"

**根因**：Codex 的压缩路径由**会话当时绑定的模型**决定：官方模型走"远程压缩"（端点硬编码为 api.openai.com，必须官方凭据）；第三方模型走"本地压缩"。会话绑定官方模型而 `auth.json` 已停用时即报此 401。

**修复**：无需改配置。将该会话切换为第三方模型后压缩自动改走本地路径，或直接开新对话。

### 问题 6：提示"无法发送消息 / 更新 Agent 沙盒以继续"

**根因**：Codex 桌面版的 Windows 沙盒（`elevated` 模式）需要管理员提权设置，常被企业 EDR 安全软件（如深信服）拦截导致失败。

**修复**（按序尝试）：

1. 将 `config.toml` 中 `sandbox = "elevated"` 改为 `"unelevated"`——无需提权，直接绕过向导；
2. 结束 Codex 进程 → 重启沙盒服务 → 删除失败的设置标记 → 重新走向导；
3. 检查 EDR 拦截日志或将 Codex 安装目录加白；最终兜底是重置整个 `.codex` 目录。

脚本选项 5 集成了流程 1+2。

### 问题 7：切回官方后，国产模型的旧对话打不开（"Model provider `custom` not found"）

**根因**：会话创建时绑定当时的 `model_provider` id（第三方模式下为 `custom`）。切回官方时 cc-switch 会删除 `config.toml` 中的 `[model_providers.custom]` 段，旧会话加载时找不到定义即报错，无法打开。

**修复**：补回一个指向 cc-switch 本地代理的 `[model_providers.custom]` 桩定义（`http://127.0.0.1:15721/v1`），旧对话即可打开查看/导出历史；续聊需在 cc-switch 中切回对应第三方供应商。脚本选项 3 已自动附带此修复，也可单独运行选项 6。

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
3. **官方额度恢复，切回官方** → cc-switch 切换 → 运行脚本选 `3`（自动恢复官方登录）→ 重启 Codex
4. **提示"更新 Agent 沙盒以继续/无法发送"** → 运行脚本选 `5` → 重启 Codex

### 非交互模式

```powershell
# 一键第三方模式修复（代理 + 认证 false + 上下文 256k）
powershell -NoProfile -ExecutionPolicy Bypass -File codex-doctor.ps1 -Fix

# 仅查看状态
powershell -NoProfile -ExecutionPolicy Bypass -File codex-doctor.ps1 -Status
```

## 特点

- **交互式菜单**：按场景分组，主菜单实时显示认证模式、上下文窗口、代理等状态
- **非交互模式**：`-Fix` / `-Status` 参数便于脚本化调用
- **无路径硬编码**：自动定位 `~/.codex`（兼容 `CODEX_HOME`），可直接复制到其他设备
- **安全可逆**：官方登录自动备份/恢复，所有修改均有确认提示

## 注意事项

- **修改生效范围**：环境变量只对新启动的进程生效；config 修改需重启 Codex 生效
- **cc-switch 覆盖问题**：每次在 cc-switch 中切换供应商，`requires_openai_auth` 和模型目录都会被重新覆盖，需重跑脚本
- **非 Windows 平台**：路径解析已兼容 `HOME` / `CODEX_HOME`，但环境变量写入可能需手动 `export`
- **已超过设定窗口的旧对话**：调小上下文窗口后需开新对话

## 排查记录（供参考）

- 代理可用性验证：直连 `api.openai.com:443` TCP 连接失败；走 `127.0.0.1:7897`（Clash）后 API 返回 401（连接正常，未带令牌的预期响应）
- 上游容量实测（qwen3.8-flash，间隔单发）：5.5 万字符 17s / 11 万字符 11s / 40 万字符 10s 均成功
- cc-switch 本地代理默认监听 `127.0.0.1:15721`，其日志位于 `~/.cc-switch/logs/cc-switch.log`
