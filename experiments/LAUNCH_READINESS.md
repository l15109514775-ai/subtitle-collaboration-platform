# 网站一键启动核验 · 2026-10-22

## 实测结论

一键启动仍未接通。现有发布版本和人工启动后的字幕回传流程保留。

- 浏览器设置能看到私有已发布环境 `subtitle-delivery-20min-active`。
- 同机 CLI `0.163.0-alpha.11` 的登录状态为 ChatGPT。
- 对固定环境执行只读 `codex cloud list --env ... --limit 1 --json` 返回
  `no cloud environments are available for this workspace`。
- 不指定环境的任务列表为 `tasks: []`。这不代表已获得该原生环境的程序启动能力。
- 该环境菜单仅观察到“编辑”“删除环境”，没有观察到外部 API 启动设置。
- 不能据此断言所有账号或所有未来版本均不支持；当前账号/渠道未通过启动验收。

## 本次已完成的本地修复（未部署）

`dispatcher/preflight.cjs` 在创建网站启动记录之前，先运行上述只读环境探测。
即使误将 `environmentVerified` 设为 true，环境不可用也不会把作业置为 submitting。
探测失败只返回固定错误码，不输出 CLI 的私有错误详情，不读取登录文件。
启动器 11 项单元测试通过（原 8 项、新增 3 项）。对真实固定环境的探测未通过；
没有提交云任务、改动业务数据、调用识别/翻译接口或启用收费资源。

## 官方接口的适配边界

1. CLI 文档有 `codex cloud exec --env`，但本账号的原生环境尚未被其识别。
   https://learn.chatgpt.com/docs/cli/reference
2. 原生环境文档把 Cloud 与 Legacy 分开。不能把旧渠道环境或另一种代理当作已验证的原生环境。
   https://learn.chatgpt.com/docs/environments/cloud-environments
3. MCP Events 文档支持 Work Cloud 的插件事件；没有建立它能直接选择/唤醒本项目
   已发布 Codex 环境的证据。需新的私有 MCP 服务、订阅持久化、授权和端到端验证。
   尚未部署插件/事件服务或订阅，也未放宽账号权限。
   https://developers.openai.com/plugins/build/mcp-events
4. Workspace Agents API 需要已发布 Workspace Agent 的 `agtch_` 触发 ID 及
   Workspace Agents 范围令牌，不能直接填本项目 `cecfg_` 环境 ID。
   当前浏览器为 Pro，未验证有相应工作区权限，未创建任何令牌。
   https://developers.openai.com/workspace-agents/trigger-runs
   https://developers.openai.com/workspace-agents/authentication

## 如用户愿意采用独立 API 方案

候选拓扑：网站认证用户 → 小型服务端启动网关 → OpenAI Agents API 托管沙箱
→ 固定版本字幕 worker → 现有 CloudBase 私有交付接口。

这需要重新准备 API 沙箱，并不是复用现有 ChatGPT 订阅中的原生环境。
原生环境仍保留；不导出浏览器会话或 CLI 登录文件。

费用：官方容器价列出 16 GiB 为每容器每 20 分钟会话 $0.48；模型控制调用另按
API token 计费。是否适用按分钟结算由官方资格决定，不假定适用。
另有现有 GPT/Qwen 供应商费用与新启动网关可能产生的腾讯云费用。
视频长 20 分钟并不意味着任务只运行 20 分钟。此报价不是单视频总价或费用上限。
https://developers.openai.com/api/docs/guides/agents-api/overview
https://developers.openai.com/api/docs/guides/agents-api/environments/openai-hosted
https://developers.openai.com/api/docs/pricing

权限：API 调用凭据只放服务端安全存储；运行端仅使用受限 worker 身份访问
用户批准的具体作业，保持有效期、400/40 限额、私有文件和人工审核边界。
该路线会新增官方 OpenAI 模型编排调用，需要用户明确允许现有“官方 key 仅用于
语音识别”规则对此用途作例外。翻译和千问识别仍可保持既有渠道。

下一步先让用户选择是否接受这种运行端与计费变化；在开启任何付费测试/新权限前，
再给出可执行的资源规格、总测试预算和权限清单。当前不创建或调用该方案。
