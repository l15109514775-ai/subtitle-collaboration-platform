# 第三方组件与许可

本仓库自己的代码、文档与新 SVG 使用根目录 AGPL-3.0-only。它不改变下列组件本身的许可。

| 组件 | 使用方式 | 来源与许可 |
| --- | --- | --- |
| js-sha256 0.11.1 | `site/sha256.min.js` 随仓库分发；保留原作者头部 | [上游](https://github.com/emn178/js-sha256)，MIT；全文见 `licenses/js-sha256-MIT.txt` |
| AstrBot v4.29.1 | 通过固定版本 Docker 镜像运行；本仓库提供插件 | [上游](https://github.com/AstrBotDevs/AstrBot/tree/v4.29.1)，AGPL-3.0；不打包其管理页面或全部源码 |
| PGlite | Node 测试依赖，从 npm 安装 | [上游](https://github.com/electric-sql/pglite)，遵循安装包的许可；未分发 node_modules |
| faster-whisper / CTranslate2 等 | Cloud 工作器依赖，由 requirements.lock 安装 | [faster-whisper](https://github.com/SYSTRAN/faster-whisper)、[CTranslate2](https://github.com/OpenNMT/CTranslate2)，遵循相应版本许可 |
| Whisper 模型转换权重 | 安装时从固定模型仓库和版本下载 | `worker/model.lock.json` 记录来源；仓库不包含模型权重，部署者检查模型卡及许可证 |
| FFmpeg | 系统工具，通过运行环境安装 | [FFmpeg 许可说明](https://ffmpeg.org/legal.html)；具体构建的 LGPL/GPL 条款由打包方式决定 |
| Python / Node.js / Docker | 运行工具 | 分别遵循上游许可；本仓库不重新分发工具本体 |

CloudBase、Codex Cloud、ChatGPT、QQ 开放平台和模型 API 是外部服务，按各自服务条款使用。开源代码不授予第三方服务、商标、账户或媒体内容的额外权利。

原项目插画缺少独立来源记录，未加入开源包。公开版的 `site/studio-banner.svg` 为本次整理新写的几何图形，不包含原截图、人物或素材。

依赖版本清单见 `package-lock.json`、`worker/requirements.lock`、`worker/requirements.clip.lock`、`worker/model.lock.json` 与 `ops/compose.yaml`。依赖更新时同步检查许可和行为兼容性。
